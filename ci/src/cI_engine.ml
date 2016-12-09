open CI_utils
open Result
open! Astring
open Lwt.Infix

module Metrics = struct
  let namespace = "DataKitCI"
  let subsystem = "engine"

  let connection_attempts =
    let help = "Number of attempted connections to DataKit" in
    CI_prometheus.Counter.v ~help ~namespace ~subsystem "connection_attempts_total"

  let connection_failures =
    let help = "Number of failed attempts to connect to DataKit" in
    CI_prometheus.Counter.v ~help ~namespace ~subsystem "connection_failures_total"

  let status_updates =
    let help = "Number of status updates" in
    CI_prometheus.Counter.v ~help ~namespace ~subsystem "status_updates_total"

  let update_notifications =
    let help = "Number of notifications from DataKit" in
    CI_prometheus.Counter.v ~help ~namespace ~subsystem "update_notifications_total"
end

type database = {
  dk : DK.t;
  gh_hooks : CI_github_hooks.t;
}

type job = {
  name : string;
  parent : target;
  mutable term : string CI_term.t;
  mutable cancel : unit -> unit;        (* Cancel the previous evaluation, if any *)
  mutable state : string * CI_state.t;                 (* The last result of evaluating [term] (commit, state) *)
}
and target = {
  project_id : CI_projectID.t;
  mutable head : [`PR of CI_github_hooks.PR.t | `Ref of CI_github_hooks.Ref.t];
  mutable jobs : job list;      (* (only mutable for init) *)
}

let job_id job =
  let target = match job.parent.head with
    | `PR pr -> `PR (CI_github_hooks.PR.id pr)
    | `Ref r -> `Ref (CI_github_hooks.Ref.name r)
  in
  ((job.parent.project_id, target), job.name)

let pp_target f target =
  match target.head with
  | `PR pr -> CI_github_hooks.PR.dump f pr
  | `Ref r -> CI_github_hooks.Ref.dump f r

let commit = function
  | `PR pr -> CI_github_hooks.PR.head pr
  | `Ref r -> CI_github_hooks.Ref.head r

let pp_job f j =
  Fmt.pf f "%a/%s" pp_target j.parent j.name

let state job = snd job.state
let git_target job = job.head
let title pr =
  match pr.head with
  | `PR pr -> CI_github_hooks.PR.title pr
  | `Ref r -> Fmt.strf "Ref %s" (CI_github_hooks.Ref.name r)
let jobs pr = pr.jobs
let job_name j = j.name
let project target = target.project_id

type project = {
  make_terms : CI_target.Full.t -> string CI_term.t String.Map.t;
  canaries : CI_target.ID_Set.t option;
  mutable open_prs : target IntMap.t;
  mutable refs : target String.Map.t;
}

type t = {
  web_ui : Uri.t;
  connect_dk : unit -> DK.t Lwt.t;
  projects : project CI_projectID.Map.t;
  term_lock : Lwt_mutex.t;              (* Held while evaluating terms *)
  mutable db : database Lwt.t;
}

let rec connect connect_dk =
  Lwt.catch
    (fun () ->
       CI_prometheus.Counter.inc_one Metrics.connection_attempts;
       connect_dk () >|= fun dk ->
       let gh_hooks = CI_github_hooks.connect dk in
       {
         dk;
         gh_hooks;
       }
    )
    (fun ex ->
       CI_prometheus.Counter.inc_one Metrics.connection_failures;
       Log.warn (fun f -> f "Failed to connect to DataKit: %s (will retry in 10s)" (Printexc.to_string ex));
       Lwt_unix.sleep 10.0 >>= fun () ->
       connect connect_dk
    )

let create ~web_ui ?canaries connect_dk projects =
  begin match canaries with
    | None -> ()
    | Some canaries -> canaries |> CI_projectID.Map.iter (fun id _ ->
        if not (CI_projectID.Map.mem id projects) then
          Log.warn (fun f -> f "Canary project %a not in list of monitored projects" CI_projectID.pp id)
      )
  end;
  let projects =
    projects |> CI_projectID.Map.mapi (fun id make_terms ->
        let canaries =
          match canaries with
          | None -> None
          | Some canaries -> Some (CI_projectID.Map.find id canaries |> default CI_target.ID_Set.empty)
        in
        {make_terms; open_prs = IntMap.empty; refs = String.Map.empty; canaries}
      )
  in
  {
    web_ui;
    connect_dk;
    db = connect connect_dk;
    projects;
    term_lock = Lwt_mutex.create ();
  }

let dk t       = t.db >|= fun db -> db.dk
let gh_hooks t = t.db >|= fun db -> db.gh_hooks

let targets t =
  t.projects |> CI_projectID.Map.map (fun project -> project.open_prs, project.refs)

let set_status t { CI_projectID.user; project } target name ~status ~descr =
  CI_prometheus.Counter.inc_one Metrics.status_updates;
  let commit, target_url =
    match target with
    | `PR pr ->
      Log.info (fun f -> f "Job %a:%s -> %s" CI_github_hooks.PR.dump pr name descr);
      let url = Uri.with_path t.web_ui (Printf.sprintf "pr/%s/%s/%d" user project (CI_github_hooks.PR.id pr)) in
      let commit = CI_github_hooks.PR.head pr in
      (commit, url)
    | `Ref r ->
      Log.info (fun f -> f "Job ref %a:%s -> %s" CI_github_hooks.Ref.dump r name descr);
      let url = Uri.with_path t.web_ui
          (Fmt.strf "ref/%s/%s/%s" user project (CI_github_hooks.Ref.name r))
      in
      let commit = CI_github_hooks.Ref.head r in
      (commit, url)
  in
  gh_hooks t >>= fun gh_hooks ->
  let message = Fmt.strf "Set state of %a: %s = %a" CI_github_hooks.Target.dump target name CI_state.pp_status status in
  CI_github_hooks.set_state gh_hooks (CI_github_hooks.CI.datakit_ci name) ~status ~descr ~target_url ~message commit

let reconnect t =
  match Lwt.state t.db with
  | Lwt.Sleep -> ()     (* Already reconnecting *)
  | Lwt.Fail _ | Lwt.Return _ ->
    Log.info (fun f -> f "Reconnecting to DataKit...");
    t.db <- connect t.connect_dk

let rec auto_restart t ?switch label fn =
  dk t >>= fun dk ->
  Lwt.catch fn
    (fun ex ->
       match switch with
       | Some switch when not (Lwt_switch.is_on switch) ->
         Log.info (fun f -> f "Switch is off, so not auto-restarting after error: %s" (Printexc.to_string ex));
         Lwt.return `Abort
       | None | Some _ ->
         DK.branch dk "master" >>= function
         | Ok _ -> Lwt.fail ex              (* Database is OK; must be something else *)
         | Error (`Msg err) ->
           Log.warn (fun f -> f "%s: database connection failed: %s\n(probable cause of %s)" label err (Printexc.to_string ex));
           reconnect t;
           auto_restart t label fn
    )

(* Note: must hold [t.term_lock] while calling this. *)
let rec recalculate t ~snapshot job =
  Log.debug (fun f -> f "Recalculate %a" pp_job job);
  let recalc () =
    Lwt.async (fun () ->
        Lwt_mutex.with_lock t.term_lock (fun () ->
            gh_hooks t >>= fun gh_hooks ->
            CI_github_hooks.snapshot gh_hooks >>= fun snapshot ->
            recalculate t ~snapshot job
          )
      )
  in
  job.cancel ();        (* Stop any previous evaluation *)
  let head = job.parent.head in
  Lwt.catch
    (fun () ->
       let r, cancel = CI_term.run ~snapshot ~job_id:(job_id job) ~recalc ~dk:(fun () -> dk t) job.term in
       job.cancel <- cancel;
       r
    )
    (function
      | Failure msg ->
        Lwt.return (Error (`Failure msg), CI_result.Step_log.Empty)
      | ex ->
        Lwt.return (Error (`Failure (Printexc.to_string ex)), CI_result.Step_log.Empty)
    )
  >>= fun (result, logs) ->
  let status, descr =
    match result with
    | Ok descr -> `Success, descr
    | Error (`Pending descr) -> `Pending, descr
    | Error (`Failure descr) -> `Failure, descr
  in
  let (old_head, old_state) = job.state in
  let new_hash = CI_github_hooks.Commit.hash (commit head) in
  begin if (old_head, old_state.CI_state.status, old_state.CI_state.descr) <> (new_hash, status, descr) then (
    set_status t job.parent.project_id head job.name ~status ~descr
  ) else (
    Lwt.return ()
  )
  end >|= fun () ->
  let state = (new_hash, { CI_state.status; descr; logs }) in
  job.state <- state

let make_job ~parent name term =
  let head_commit = commit parent.head in
  let dk_state = CI_github_hooks.Commit.state (CI_github_hooks.CI.datakit_ci name) head_commit in
  CI_github_hooks.Commit_state.status dk_state >>= fun status ->
  CI_github_hooks.Commit_state.descr dk_state >>= fun descr ->
  let state =
    match status, descr with
    | Some status, Some descr -> { CI_state.status; descr; logs = CI_result.Step_log.Empty }
    | _ -> { CI_state.status = `Pending; descr = "(new)"; logs = CI_result.Step_log.Empty }
  in
  let hash = CI_github_hooks.Commit.hash head_commit in
  Lwt.return {
    name;
    parent;
    term;
    cancel = ignore;
    state = (hash, state);
  }

let apply_canaries canaries prs refs =
  match canaries with
  | None -> (prs, refs)
  | Some canaries ->
    let prs = prs |> IntMap.filter (fun id _ -> CI_target.ID_Set.mem (`PR id) canaries) in
    let refs = refs |> String.Map.filter (fun id _ -> CI_target.ID_Set.mem (`Ref id) canaries) in
    (prs, refs)

let listen ?switch t =
  auto_restart t ?switch "monitor" @@ fun () ->
  Log.info (fun f -> f "Starting monitor loop");
  gh_hooks t >>= fun gh_hooks ->
  let check_pr ~snapshot ~project_id project (id, pr) =
    Log.debug (fun f -> f "Checking for work on %a" CI_github_hooks.PR.dump pr);
    begin match IntMap.find id project.open_prs with
      | None ->
        let open_pr = {
          project_id;
          head = `PR pr;
          jobs = [];
        } in
        let terms = project.make_terms (project_id, `PR id) in
        String.Map.bindings terms
        |> Lwt_list.map_s (fun (name, term) -> make_job ~parent:open_pr name term)
        >>= fun jobs ->
        open_pr.jobs <- jobs;
        project.open_prs <- IntMap.add id open_pr project.open_prs;
        Lwt.return open_pr
      | Some open_pr ->
        open_pr.head <- `PR pr; (* Update in all cases, because we read other things from the same snapshot.
                                   XXX: so compare is very misleading here! *)
        Lwt.return open_pr
    end >>= fun open_pr ->
    Lwt_list.iter_s (recalculate t ~snapshot) open_pr.jobs
  in
  let check_ref ~snapshot ~project_id project (id, r) =
    Log.debug (fun f -> f "Checking for work on %a" CI_github_hooks.Ref.dump r);
    begin match String.Map.find id project.refs with
      | None ->
        let target = {
          project_id;
          head = `Ref r;
          jobs = [];
        } in
        let terms = project.make_terms (project_id, `Ref id) in
        String.Map.bindings terms
        |> Lwt_list.map_s (fun (name, term) -> make_job ~parent:target name term)
        >>= fun jobs ->
        target.jobs <- jobs;
        project.refs <- String.Map.add id target project.refs;
        Lwt.return target
      | Some target ->
        target.head <- `Ref r;
        Lwt.return target
    end >>= fun target ->
    Lwt_list.iter_s (recalculate t ~snapshot) target.jobs
  in
  CI_github_hooks.enable_monitoring gh_hooks (List.map fst (CI_projectID.Map.bindings t.projects)) >>= fun () ->
  CI_github_hooks.monitor ?switch gh_hooks (fun snapshot ->
      CI_prometheus.Counter.inc_one Metrics.update_notifications;
      t.projects |> CI_projectID.Map.bindings |> Lwt_list.iter_s (fun (project_id, project) ->
          CI_github_hooks.Snapshot.project snapshot project_id >>= fun (prs, refs) ->
          Log.debug (fun f -> f "Monitor iter");
          let prs, refs = apply_canaries project.canaries prs refs in
          (* PRs *)
          let is_current id open_pr =
            let current = IntMap.mem id prs in
            if not current then (
              Log.info (fun f -> f "Removing closed PR#%d" id);
              List.iter (fun j -> j.cancel ()) open_pr.jobs
            );
            current
          in
          project.open_prs <- IntMap.filter is_current project.open_prs;
          Lwt_mutex.with_lock t.term_lock (fun () ->
              IntMap.bindings prs |> Lwt_list.iter_s (check_pr ~snapshot ~project_id project)
            )
          >>= fun () ->
          (* Refs *)
          let is_current id target =
            let current = String.Map.mem id refs in
            if not current then (
              Log.info (fun f -> f "Removing closed branch %s" id);
              List.iter (fun j -> j.cancel ()) target.jobs
            );
            current
          in
          project.refs <- String.Map.filter is_current project.refs;
          Lwt_mutex.with_lock t.term_lock (fun () ->
              String.Map.bindings refs |> Lwt_list.iter_s (check_ref ~snapshot ~project_id project)
            )
        )
    )

let rebuild t ~branch_name =
  let jobs_needing_recalc = ref [] in
  let triggers = ref [] in
  let rec check_logs =
    let open CI_result.Step_log in
    function
    | Saved {branch; rebuild; _} when branch = branch_name ->
      if not (Lazy.is_val rebuild) then triggers := Lazy.force rebuild :: !triggers;
      true
    | Saved _ -> false
    | Empty -> false
    | Pair (a, b) ->
      let a = check_logs a in
      let b = check_logs b in
      a || b
    | Live _ -> false
  in
  let check_job job =
    let _, state = job.state in
    if check_logs state.CI_state.logs then
      jobs_needing_recalc := job :: !jobs_needing_recalc
  in
  let check_target target = List.iter check_job target.jobs in
  t.projects |> CI_projectID.Map.iter (fun _ project ->
      project.open_prs |> IntMap.iter (fun _ x -> check_target x);
      project.refs |> String.Map.iter (fun _ x -> check_target x);
    );
  match !triggers, !jobs_needing_recalc with
  | [], [] -> CI_utils.failf "No job depends on %S, so can't rebuild anything" branch_name
  | triggers, jobs_needing_recalc ->
    Lwt.join triggers >>= fun () ->
    Lwt_mutex.with_lock t.term_lock (fun () ->
        gh_hooks t >>= fun gh_hooks ->
        CI_github_hooks.snapshot gh_hooks >>= fun snapshot ->
        Lwt_list.iter_s (recalculate t ~snapshot) jobs_needing_recalc
      )

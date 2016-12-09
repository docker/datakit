let refs_dir = Datakit_path.of_string_exn "ref"
let prs_dir = Datakit_path.of_string_exn "pr"
let commits_dir = Datakit_path.of_string_exn "commit"

let metadata_branch = "github-metadata"

open! Datakit_path.Infix

open CI_utils
open Result
open! Astring
open Lwt.Infix

type t = DK.t

type project_snapshot = {
  project_id : CI_projectID.t;
  root : DK.Tree.t;
}

let read_file { project_id; root } path =
  let path = CI_projectID.path project_id /@ path in
  DK.Tree.read_file root path

let ensure_removed t path =
  DK.Transaction.remove t path >|= function
  | Ok () -> ()
  | Error (`Msg "No such file or directory") -> ()
  | Error (`Msg msg) -> failf "Error removing %a: %s" Datakit_path.pp path msg

let read_string snapshot path =
  read_file snapshot path >|= function
  | Ok x -> Ok (Cstruct.to_string x)
  | Error _ as e -> e

module Commit_state = struct
  type t = {
    snapshot : project_snapshot;
    path : Datakit_path.t; (* Relative to snapshot *)
  }

  let read t leaf fn =
    let path = t.path / leaf in
    read_file t.snapshot path >|= function
    | Ok data -> Some (fn (String.trim (Cstruct.to_string data)))
    | Error (`Msg "No such file or directory") -> None
    | Error (`Msg msg) -> failf "Reading %a: %s" Datakit_path.pp path msg

  let status t = read t "state" CI_state.status_of_string
  let descr t = read t "description" (fun x -> x)
  let target_url t = read t "target_url" Uri.of_string
end

module CI = struct
  type t = Datakit_path.t

  let of_string = Datakit_path.of_string_exn
  let circle_ci = Datakit_path.of_string_exn "ci/circleci"
  let datakit_ci x = Datakit_path.of_string_exn "ci/datakit" / x
end

module Commit = struct
  type t = {
    snapshot : project_snapshot;
    hash : string;
  }

  let project t = t.snapshot.project_id

  let hash t = t.hash

  let state ci t =
    { Commit_state.snapshot = t.snapshot; path = commits_dir / t.hash / "status" /@ ci }

  let pp f t = Fmt.string f (String.with_range ~len:6 t.hash)

  let compare a b =
    compare a.hash b.hash
end

module PR = struct
  type t = {
    id : int;
    commit : Commit.t;
    title : string;
  }

  let id t = t.id
  let head t = t.commit
  let title t = t.title
  let project t = Commit.project t.commit

  let dump f t = Fmt.pf f "PR#%d (commit=%a;title=%s)" t.id Commit.pp t.commit t.title

  let compare a b =
    match compare a.id b.id with
    | 0 -> Commit.compare a.commit b.commit
    | r -> r
end

module Ref = struct
  type t = {
    name : string;
    head : Commit.t;
  }

  let project t = Commit.project t.head
  let name t = t.name
  let head t = t.head
  let dump f t = Fmt.pf f "ref/%s (head=%a)" t.name Commit.pp t.head

  let compare a b =
    match String.compare a.name b.name with
    | 0 -> Commit.compare a.head b.head
    | r -> r
end

let connect gh = gh

let set_state t ci ~status ~descr ?target_url ~message commit =
  DK.branch t metadata_branch >>*= fun metadata ->
  DK.Branch.with_transaction metadata (fun t ->
      let snapshot = commit.Commit.snapshot in
      let dir = CI_projectID.path snapshot.project_id /@ commits_dir / commit.Commit.hash / "status" /@ ci in
      DK.Transaction.make_dirs t dir >>*= fun () ->
      let update leaf data =
        DK.Transaction.create_or_replace_file t (dir / leaf) (Cstruct.of_string (data ^ "\n"))
        >>*= Lwt.return in
      update "state" (Fmt.to_to_string CI_state.pp_status status) >>= fun () ->
      update "description" descr >>= fun () ->
      begin match target_url with
        | None -> ensure_removed t (dir / "target_url")
        | Some url -> update "target_url" (Uri.to_string url)
      end >>= fun () ->
      Log.debug (fun f -> f "set_state: %s" message);
      DK.Transaction.commit t ~message
    ) >>*= Lwt.return

let pr snapshot id =
  let id_leaf = string_of_int id in
  read_string snapshot (prs_dir / id_leaf / "head") >>= function
  | Error _ -> Log.err (fun f -> f "Missing head for PR %d" id); Lwt.return None
  | Ok commit ->
    let commit = { Commit.hash = String.trim commit; snapshot } in
    read_string snapshot (prs_dir / id_leaf / "title") >|= fun title ->
    let title =
      match title with
      | Error (`Msg m) ->
        Log.err (fun f -> f "Bad title for PR %d: %s" id m);
        Fmt.strf "Bad title: %s" m
      | Ok t -> String.trim t in
    Some { PR.id; commit; title }

let read_opt_file snapshot path =
  read_file snapshot path >|= function
  | Ok data -> Some data
  | Error (`Msg "No such file or directory") -> None
  | Error e -> failf "Error reading %a: %a" Datakit_path.pp path DK.pp_error e

let read_opt_dir {project_id; root} path =
  let path = CI_projectID.path project_id /@ path in
  DK.Tree.read_dir root path >|= function
  | Ok items -> items
  | Error (`Msg "No such file or directory") -> []
  | Error e -> failf "Error reading %a: %a" Datakit_path.pp path DK.pp_error e

let prs snapshot =
  read_opt_dir snapshot prs_dir >>=
  Lwt_list.fold_left_s (fun acc id ->
      match String.to_int id with
      | None -> Log.warn (fun f -> f "Invalid PR ID %S" id); Lwt.return acc
      | Some id -> pr snapshot id >|= function
        | None -> acc
        | Some value -> IntMap.add id value acc
    ) IntMap.empty

let refs snapshot =
  let open! Datakit_path.Infix in
  let results = ref String.Map.empty in
  let rec scan ~context leaf =
    let context = context / leaf in
    read_opt_file snapshot (refs_dir /@ context / "head") >>= function
    | Some head ->
      let hash = String.trim (Cstruct.to_string head) in
      let head = { Commit.snapshot; hash } in
      let name = Datakit_path.to_hum context in
      results := String.Map.add name { Ref.head; name } !results;
      Lwt.return ()
    | None ->
      read_opt_dir snapshot (refs_dir /@ context) >>=
      Lwt_list.iter_s (scan ~context)
  in
  read_opt_dir snapshot refs_dir >>=
  Lwt_list.iter_s (scan ~context:Datakit_path.empty) >|= fun () ->
  !results

module Target = struct
  type t = [ `PR of PR.t | `Ref of Ref.t ]

  let dispatch p r = function
    | `PR x -> p x
    | `Ref x -> r x

  let head = dispatch PR.head Ref.head

  let dump f = function
    | `PR x -> PR.dump f x
    | `Ref x -> Ref.dump f x
end

module Snapshot = struct
  type t = {
    commit : DK.Commit.t;
    mutable projects : (PR.t CI_utils.IntMap.t * Ref.t String.Map.t) Lwt.t CI_projectID.Map.t;
  }

  let project t project_id =
    match CI_projectID.Map.find project_id t.projects with
    | Some p -> p
    | None ->
      let p =
        let root = DK.Commit.tree t.commit in
        let p_snapshot = { project_id; root } in
        prs p_snapshot >>= fun prs ->
        refs p_snapshot >>= fun refs ->
        Lwt.return (prs, refs)
      in
      t.projects <- CI_projectID.Map.add project_id p t.projects;
      p

  let ( >|?= ) x f =
    match x with
    | None -> None
    | Some y -> Some (f y)

  let find id t =
    project t (CI_target.Full.project id) >|= fun (prs, refs) ->
    match CI_target.Full.id id with
    | `PR pr -> IntMap.find pr prs >|?= fun x -> `PR x
    | `Ref x ->
      match String.Map.find x refs with
      | None   -> None
      | Some x -> Some (`Ref x)
end

let snapshot t =
  DK.branch t metadata_branch >>*= fun metadata ->
  DK.Branch.head metadata >|*= function
  | None -> failf "Metadata branch does not exist!"
  | Some commit -> { Snapshot.commit; projects = CI_projectID.Map.empty }

let enable_monitoring t projects =
  DK.branch t metadata_branch >>*= fun metadata_branch ->
  DK.Branch.with_transaction metadata_branch (fun tr ->
      let changes = ref false in
      projects |> Lwt_list.iter_s (fun p ->
          let dir = CI_projectID.path p in
          let path = dir / ".monitor" in
          DK.Transaction.exists_file tr path >>*= function
          | true -> Lwt.return ()
          | false ->
            Log.info (fun f -> f "Adding monitor file for %a" Datakit_path.pp path);
            changes := true;
            DK.Transaction.make_dirs tr dir >>*= fun () ->
            DK.Transaction.create_file tr path (Cstruct.of_string "") >|*= fun () -> ()
        )
      >>= fun () ->
      if !changes then (
        DK.Transaction.commit tr ~message:"Add .monitor files"
      ) else (
        DK.Transaction.abort tr >|= fun () -> Ok ()
      )
    )
  >>*= fun () ->
  Lwt.return ()

let monitor t ?switch fn =
  DK.branch t metadata_branch >>*= fun metadata ->
  DK.Branch.wait_for_head metadata ?switch (function
      | None -> ok `Again
      | Some commit ->
        let snapshot = { Snapshot.commit; projects = CI_projectID.Map.empty } in
        fn snapshot >>= fun () -> ok `Again
    )
  >|*= function
  | `Abort -> `Abort
  | `Finish `Never -> assert false

let pr t ~project_id id =
  DK.branch t metadata_branch >>*= fun metadata ->
  DK.Branch.head metadata >>*= function
  | None -> Lwt.return None
  | Some head ->
    let root = DK.Commit.tree head in
    pr { project_id; root } id

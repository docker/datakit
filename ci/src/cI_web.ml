open Datakit_github
open! Astring
open Lwt.Infix
open CI_utils
open CI_utils.Infix

module Wm = CI_web_utils.Wm
module Rd = Webmachine.Rd

type t = {
  ci : CI_engine.t;
  logs : CI_live_log.manager;
  server : CI_web_utils.server;
  dashboards : CI_target.Set.t Repo.Map.t;
}

class user_page t = object(self)
  inherit CI_web_utils.html_page t.server

  method private required_roles = [`LoggedIn]

  method private render rd =
    self#session rd >>= fun session_data ->
    let csrf_token = CI_web_utils.Session_data.csrf_token session_data in
    Wm.continue (CI_web_templates.user_page ~csrf_token) rd
end

class main t = object(self)
  inherit CI_web_utils.html_page t.server

  method private required_roles = [`Reader]

  method private render rd =
    self#session rd >>= fun session_data ->
    let csrf_token = CI_web_utils.Session_data.csrf_token session_data in
    Wm.continue (CI_web_templates.main_page ~csrf_token ~ci:t.ci ~dashboards:t.dashboards) rd
end

class error t = object
  inherit CI_web_utils.html_page t.server

  method private required_roles = []

  method private render rd =
    let id = Rd.lookup_path_info_exn "id" rd in
    Wm.continue (CI_web_templates.error_page id) rd
end

class pr_list t = object
  inherit CI_web_utils.html_page t.server

  method private required_roles = [`Reader]

  method private render rd = Wm.continue (CI_web_templates.prs_page ~ci:t.ci) rd
end

class branch_list t = object
  inherit CI_web_utils.html_page t.server

  method private required_roles = [`Reader]

  method private render rd = Wm.continue (CI_web_templates.branches_page ~ci:t.ci) rd
end

class tag_list t = object
  inherit CI_web_utils.html_page t.server

  method private required_roles = [`Reader]

  method private render rd = Wm.continue (CI_web_templates.tags_page ~ci:t.ci) rd
end

class pr_page t = object(self)
  inherit CI_web_utils.html_page t.server

  method private required_roles = [`Reader]

  method private render rd =
    let user = Rd.lookup_path_info_exn "user" rd in
    let repo = Rd.lookup_path_info_exn "repo" rd in
    let id = Rd.lookup_path_info_exn "id" rd in
    let id = int_of_string id in
    let repo = Repo.v ~user ~repo in
    let prs = CI_engine.prs t.ci in
    match Repo.Map.find repo prs with
    | None  -> Wm.respond 404 rd ~body:(`String "No such project")
    | Some prs ->
      match PR.Index.find (repo, id) prs with
      | None -> Wm.respond 404 rd ~body:(`String "No such open PR")
      | Some target ->
        let jobs = CI_engine.jobs target in
        self#session rd >>= fun session_data ->
        let csrf_token = CI_web_utils.Session_data.csrf_token session_data in
        Wm.continue (CI_web_templates.target_page ~csrf_token ~target jobs) rd
end

class ref_page t = object(self)
  inherit CI_web_utils.html_page t.server

  method private required_roles = [`Reader]

  method private render rd =
    let user = Rd.lookup_path_info_exn "user" rd in
    let repo = Rd.lookup_path_info_exn "repo" rd in
    let id = CI_target.unescape_ref rd.Rd.dispatch_path in
    let repo = Repo.v ~user ~repo in
    let refs = CI_engine.refs t.ci in
    match Repo.Map.find repo refs with
    | None -> Wm.respond 404 rd ~body:(`String "No such project")
    | Some refs ->
      match Ref.Index.find (repo, id) refs with
      | None        -> Wm.respond 404 rd ~body:(`String "No such ref")
      | Some target ->
        let jobs = CI_engine.jobs target in
        self#session rd >>= fun session_data ->
        let csrf_token = CI_web_utils.Session_data.csrf_token session_data in
        Wm.continue (CI_web_templates.target_page ~csrf_token ~target jobs) rd
end

class live_log_page t = object(self)
  inherit CI_web_utils.protected_page t.server

  method content_types_provided rd =
    Wm.continue [
      "text/html" , self#to_html;
    ] rd

  method content_types_accepted rd =
    Wm.continue [] rd

  method private required_roles = [`Reader]

  method private to_html rd =
    let branch = Uri.pct_decode (Rd.lookup_path_info_exn "branch" rd) in
    let user = self#authenticated_user in
    let web_config = CI_web_utils.web_config t.server in
    CI_engine.dk t.ci >>= fun dk ->
    DK.branch dk branch >>*= fun b ->
    DK.Branch.head b >>*= fun head ->
    match CI_live_log.lookup t.logs ~branch with
    | None ->
      (* todo: find out what commit it turned into and serve that instead *)
      begin match head with
        | Some head ->
          let path = CI_web_templates.saved_log_frame_link ~branch ~commit:(DK.Commit.id head) in
          Wm.respond 307 (Rd.redirect path rd)
        | None ->
          Log.warn (fun f -> f "Live log %S not found, and no saved branch either" branch);
          Wm.respond 500 rd ~body:(`String "Log finished, but wasn't saved!")
      end
    | Some live_log ->
      let have_history = head <> None in
      let html = CI_web_templates.live_log_frame ~branch ~have_history in
      let template = Fmt.to_to_string (Tyxml.Html.pp ()) (html ~user web_config) in
      match String.cut ~sep:"@STREAM-GOES-HERE@" template with
      | None -> CI_utils.failf "Bad template output %S" template
      | Some (head, tail) ->
        let stream, out = Lwt_stream.create_bounded 100 in
        CI_live_log.stream live_log >>= fun src ->
        out#push head >>= fun () ->
        Lwt.async (fun () ->
            Lwt.catch
              (fun () ->
                 let rec aux = function
                   | None ->
                     out#push tail >>= fun () ->
                     out#close;
                     Lwt.return ()
                   | Some {CI_live_log.data; next} ->
                     out#push (Xml_print.encode_unsafe_char data) >>= fun () ->
                     Lazy.force next >>= aux
                 in
                 aux src
              )
              (fun ex ->
                 Log.warn (fun f -> f "Error streaming log: %a" CI_utils.pp_exn ex);
                 Lwt.return ()
              )
          );
        Wm.continue
          (`Stream stream)
          { rd with
            (* Otherwise, an nginx reverse proxy will wait for the whole log before sending anything. *)
            Rd.resp_headers = Cohttp.Header.add rd.Rd.resp_headers "X-Accel-Buffering" "no";
          }
end

class saved_log_page t = object
  inherit CI_web_utils.html_page t.server

  method private required_roles = [`Reader]

  method private render rd =
    let branch = Uri.pct_decode (Rd.lookup_path_info_exn "branch" rd) in
    let commit = Rd.lookup_path_info_exn "commit" rd in
    CI_engine.dk t.ci >>= fun dk ->
    let tree = DK.Commit.tree (DK.commit dk commit) in
    DK.Tree.read_file tree CI_cache.Path.log >>= function
    | Error (`Msg e) -> Wm.continue (CI_web_templates.plain_error e) rd
    | Ok log_data ->
      Wm.continue (CI_web_templates.saved_log_frame ~commit ~branch ~log_data) rd
end

class rebuild t = object
  inherit CI_web_utils.post_page t.server

  method private required_roles = [`Builder]

  method! private process_post rd =
    let branch_name = Rd.lookup_path_info_exn "branch" rd in
    match Uri.get_query_param rd.Rd.uri "redirect" with
    | None -> Wm.respond ~body:(`String "Missing redirect") 400 rd
    | Some redirect ->
      CI_engine.rebuild t.ci ~branch_name >>= fun () ->
      Wm.continue true (Rd.redirect redirect rd)
end

class cancel t = object
  inherit CI_web_utils.post_page t.server

  method private required_roles = [`Builder]

  method! private process_post rd =
    let branch = Rd.lookup_path_info_exn "branch" rd in
    match CI_live_log.lookup ~branch t.logs with
    | None ->
      let body = Fmt.strf "Branch %S is not currently building" branch in
      Wm.respond ~body:(`String body) 404 rd
    | Some log ->
      CI_live_log.cancel log >>= function
      | Ok () -> Wm.continue true (Rd.redirect "/" rd)
      | Error body -> Wm.respond ~body:(`String body) 404 rd
end

module Settings = struct
  class index t = object
    inherit CI_web_utils.html_page t.server

    method private required_roles = [`Admin]

    method private render rd =
      Wm.continue (CI_web_templates.Settings.index) rd
  end
end

let mime_type uri =
  match String.take ~sat:((<>) '.') ~rev:true (Uri.path uri) with
  | "css"   -> Some "text/css"
  | "js"    -> Some "text/javascript"
  | "eot"   -> Some "application/vnd.ms-fontobject"
  | "svg"   -> Some "image/svg+xml"
  | "ttf"   -> Some "application/x-font-ttf"
  | "woff"  -> Some "application/font-woff"
  | "woff2" -> Some "font/woff2"
  | "png"   -> Some "image/png"
  | _       -> None

let routes ~logs ~ci ~server ~dashboards =
  let t = { logs; ci; server; dashboards } in
  [
    (* Auth *)
    ("auth/intro/:token", fun () -> new CI_web_utils.auth_intro t.server);
    ("auth/setup",     fun () -> new CI_web_utils.auth_setup t.server);
    ("auth/login",     fun () -> new CI_web_utils.login_page t.server);
    ("auth/logout",    fun () -> new CI_web_utils.logout_page t.server);
    ("auth/github-callback",    fun () -> new CI_web_utils.github_callback t.server);
    ("user/profile",   fun () -> new user_page t);
    (* Overview pages *)
    ("/",               fun () -> new main t);
    ("pr",              fun () -> new pr_list t);
    ("branch",          fun () -> new branch_list t);
    ("tag",             fun () -> new tag_list t);
    (* Individual targets *)
    (":user/:repo/pr/:id",     fun () -> new pr_page t);
    (":user/:repo/ref/*",      fun () -> new ref_page t);
    (* Logs *)
    ("log/live/:branch",                        fun () -> new live_log_page t);
    ("log/saved/:branch/:commit",               fun () -> new saved_log_page t);
    ("log/rebuild/:branch",                     fun () -> new rebuild t);
    ("cancel/:branch",                          fun () -> new cancel t);
    (* Settings *)
    ("settings",        fun () -> new Settings.index t);
    ("settings/github-auth", fun () -> new CI_web_utils.github_auth_settings t.server);
    (* Errors *)
    ("error/:id",       fun () -> new error t);
    (* Static resources *)
    (":dir/:name",      fun () -> new CI_web_utils.static_crunch ~mime_type CI_static.read);
  ]

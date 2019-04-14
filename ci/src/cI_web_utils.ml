open Datakit_github
open! Astring
open Sexplib.Std
open Lwt.Infix

module Log = CI_utils.Log
module Server = Cohttp_lwt_unix.Server

module Metrics = struct
  open Prometheus

  let namespace = "DataKitCI"
  let subsystem = "web"

  let record_request =
    let help = "HTTP requests to web UI" in
    let metric = Counter.v_label ~help ~label_name:"method" ~namespace ~subsystem "requests_total" in
    fun req -> Counter.inc_one (metric (Cohttp.(Code.string_of_method (Request.meth req))))

  let record_response =
    let help = "HTTP responses from web UI" in
    let metric = Counter.v_label ~help ~label_name:"code" ~namespace ~subsystem "responses_total" in
    fun code -> Counter.inc_one (metric (Cohttp.(Code.string_of_status code)))

  let requests_in_progress =
    let help = "HTTP requests currently being handled by the web UI" in
    Gauge.v ~help ~namespace ~subsystem "requests_in_progress"

  let local_login_ok_total =
    let help = "Number of successful local login attempts" in
    Counter.v ~help ~namespace ~subsystem "local_login_ok_total"

  let local_login_rejected_total =
    let help = "Number of unsuccessful local login attempts" in
    Counter.v ~help ~namespace ~subsystem "local_login_rejected_total"

  let github_login_ok_total =
    let help = "Number of successful GitHub login attempts" in
    Counter.v ~help ~namespace ~subsystem "github_login_ok_total"

  let github_login_rejected_total =
    let help = "Number of unsuccessful GitHub login attempts" in
    Counter.v ~help ~namespace ~subsystem "github_login_rejected_total"

  let response_time_seconds =
    let help = "Time to handle one web request" in
    Summary.v ~help ~namespace ~subsystem "response_time_seconds"
end

module Wm = struct
  module Rd = Webmachine.Rd
  module UnixClock = struct
    let now = fun () -> int_of_float (Unix.gettimeofday ())
  end
  include Webmachine.Make(Cohttp_lwt_unix.IO)(UnixClock)
end
module Session = struct
  module Memory = Session.Lift.IO(Lwt)(Session.Memory)
  module Backend = struct
    type t =
      [ `Memory of Memory.t
      | `Redis of Session_redis_lwt.t ]

    type 'a io = 'a Lwt.t
    type key = string
    type value = string
    type period = int64

    let default_period = function
      | `Memory t -> Memory.default_period t
      | `Redis t -> Session_redis_lwt.default_period t

    let generate ?expiry ?value = function
      | `Memory t -> Memory.generate ?expiry ?value t
      | `Redis t -> Session_redis_lwt.generate ?expiry ?value t

    let clear t key =
      match t with
      | `Memory t -> Memory.clear t key
      | `Redis t -> Session_redis_lwt.clear t key

    let get t key =
      match t with
      | `Memory t -> Memory.get t key
      | `Redis t -> Session_redis_lwt.get t key

    let set ?expiry t key value =
      match t with
      | `Memory t -> Memory.set ?expiry t key value
      | `Redis t -> Session_redis_lwt.set ?expiry t key value
  end
  include Session_webmachine.Make(Lwt)(Backend)
  let connect = function
    | `Memory -> `Memory (Session.Memory.create ())
    | `Redis pool -> `Redis (Session_redis_lwt.of_connection_pool pool)
end

let () =
  Nocrypto_entropy_unix.initialize ()

type role = [`Reader | `LoggedIn | `Builder | `Admin]

module Hashed_password = struct
  type t = {
    prf : [`SHA1];
    salt : Cstruct_sexp.t;
    hashed_password : Cstruct_sexp.t;
    count : int;
    dk_len : int32;
  } [@@deriving sexp]

  let matches t ~password =
    let hashed_user_input =
      Pbkdf.pbkdf2
        ~prf:(t.prf :> Nocrypto.Hash.hash)
        ~count:t.count
        ~dk_len:t.dk_len
        ~salt:t.salt
        ~password:(Cstruct.of_string password)
    in
    Cstruct.equal hashed_user_input t.hashed_password

  let of_plain ~password =
    let prf = `SHA1 in
    let count = 5000 in
    let dk_len = 20l in
    let salt = Nocrypto.Rng.generate 16 in
    let hashed_password = Pbkdf.pbkdf2 ~prf ~count ~dk_len ~salt ~password:(Cstruct.of_string password) in
    { prf; count; dk_len; salt; hashed_password }
end

module User = struct
  type t = {
    name : string;
    password : Hashed_password.t;
  }

  let name t = t.name
end

module Auth = struct
  type password_file = (string * Hashed_password.t) list [@@deriving sexp]
  module Repo = struct
    include Repo
    let t_of_sexp s =
      let user, repo =
        let open !Sexplib.Conv in
        pair_of_sexp string_of_sexp string_of_sexp s
      in
      let user = Datakit_github.User.v user in
      Repo.v ~user ~repo
    let sexp_of_t t =
      let open !Sexplib.Conv in
      let user = Datakit_github.User.name t.Repo.user in
      sexp_of_pair sexp_of_string sexp_of_string (user, t.Repo.repo)
  end
  type user_attributes = {
    github_orgs : string list;
    can_read_github : (Repo.t * bool) list;
  } [@@deriving sexp]

  type t = {
    passwd_file : string;
    github : CI_secrets.github_auth CI_secrets.secret;
    github_scopes_needed : Github_t.scope list;
    mutable local_users : [`Configured of User.t String.Map.t | `Config_token of string];
  }

  let empty_attrs = { github_orgs = []; can_read_github = [] }

  let is_configured t =
    match t.local_users with
    | `Config_token _ -> false
    | `Configured _ -> true

  let lookup t ~user ~password =
    match t.local_users with
    | `Config_token _ -> Log.info (fun f -> f "Local users not configured yet"); None
    | `Configured user_db ->
      match String.Map.find user user_db with
      | Some ({ User.password = stored_pw; _ } as user)
        when Hashed_password.matches ~password stored_pw -> Some user
      | Some _ -> Log.info (fun f -> f "Incorrect password for user %S" user); None
      | None -> Log.info (fun f -> f "No such user %S" user); None

  let load_local_users passwd_file =
    Lwt_io.with_file ~mode:Lwt_io.input passwd_file (fun ch -> Lwt_io.read ch) >|= fun contents ->
    password_file_of_sexp (Sexplib.Sexp.of_string contents)
    |> String.Map.of_list
    |> String.Map.mapi (fun name password -> { User.name; password })

  let try_load_local_users ~web_ui ~passwd_file =
    if Sys.file_exists passwd_file then (
      load_local_users passwd_file >|= fun db -> `Configured db
    ) else (
      let token = Base64.(encode_string ~alphabet:uri_safe_alphabet) (Nocrypto.Rng.generate 24 |> Cstruct.to_string) in
      let setup_url = Uri.with_path web_ui ("/auth/intro/" ^ token) in
      Log.app (fun f -> f ">>> Configure the CI by visiting@\n%a" Uri.pp_hum setup_url);
      Lwt.return (`Config_token token)
    )

  let tokens_equal a b =
    Nocrypto.Uncommon.Cs.ct_eq (Cstruct.of_string a) (Cstruct.of_string b)

  let check_setup_token t token =
    match t.local_users with
    | `Config_token required when tokens_equal required token -> Ok ()
    | `Configured _ -> Error "Already initialised - log in as admin"
    | `Config_token _ -> Error "Bad token"

  let initialise_local_users t ~password =
    match t.local_users with
    | `Configured _ ->
      (* For now, we only allow the admin password to be set once.
         If we want to allow changes too, need to think about protecting other users in the DB. *)
      Lwt.return @@ Error "Already configured!"
    | `Config_token _ ->
      let user = "admin" in
      let entry = Hashed_password.of_plain ~password in
      let contents =
        [user, entry]
        |> sexp_of_password_file
        |> Sexplib.Sexp.to_string in
      Lwt_io.with_file ~mode:Lwt_io.output t.passwd_file (fun ch -> Lwt_io.write ch contents) >>= fun () ->
      load_local_users t.passwd_file >>= fun local_users ->
      t.local_users <- `Configured local_users;
      Lwt.return @@ Ok ()

  let create ~github ~github_scopes_needed ~web_ui passwd_file =
    if Filename.is_relative passwd_file then CI_utils.failf "Path %S is relative" passwd_file;
    try_load_local_users ~web_ui ~passwd_file >>= fun local_users ->
    Lwt.return { passwd_file; github; github_scopes_needed; local_users }

  let github_login_url ~csrf_token t =
    match CI_secrets.get t.github with
    | None -> None
    | Some github ->
      let url = Github.URI.authorize
          ~scopes:t.github_scopes_needed
          ~client_id:github.CI_secrets.client_id
          ?redirect_uri:github.CI_secrets.callback
          ~state:csrf_token
          ()
      in
      Some url

  let handle_github_callback t ~code ~repos =
    match CI_secrets.get t.github with
    | None -> Lwt.return @@ Error "GitHub auth is not configured!"
    | Some github ->
      Github.Token.of_code ~client_id:github.CI_secrets.client_id ~client_secret:github.CI_secrets.client_secret ~code () >>= function
       | None -> Lwt.return @@ Error "Token.of_code failed (no further information available)"
       | Some token ->
         Github.Monad.run (Github.User.current_info ~token ()) >>= fun resp ->
         let user_info = Github.Response.value resp in
         Github.Monad.run begin
           let open! Github.Monad in
           Github.User.current_info ~token () >|= Github.Response.value >>= fun user_info ->
           let user = user_info.Github_t.user_info_login in
           Github.Organization.user_orgs ~token ~user () |> Github.Stream.to_list >|= fun orgs ->
           let orgs = List.map (fun org -> org.Github_t.org_login) orgs in
           Log.info (fun f -> f "User %S belongs to %a" user (Fmt.Dump.list Fmt.string) orgs);
           orgs
         end >>= fun github_orgs ->
         let user = "github:" ^ user_info.Github_t.user_info_login in
         let can_read_github project =
           Lwt.try_bind (fun () ->
               Github.Monad.run begin
                 let open! Github.Monad in
                 let {Repo.user; repo} = project in
                 let user = Datakit_github.User.name user in
                 Github.Repo.info ~token ~user ~repo () >|= Github.Response.value
               end
             )
             (fun (_:Github_t.repository) ->
                 Log.info (fun f -> f "%S can read %a" user Repo.pp project);
                 Lwt.return true
             )
             (fun ex ->
                Log.info (fun f -> f "%S can't read %a" user Repo.pp project);
                Log.debug (fun f -> f "%S can't read %a: %a" user Repo.pp project Fmt.exn ex);
                Lwt.return false
             )
         in
         Lwt_list.map_s (fun p -> can_read_github p >|= fun flag -> (p, flag)) repos >>= fun can_read_github ->
         let attributes = {
           github_orgs;
           can_read_github;
         } in
         Lwt.return (Ok (user, attributes))
end

type server = {
  auth : Auth.t;
  session_backend : Session.Backend.t;
  web_config : CI_web_templates.t;
  secure_cookies : bool;
  has_role :
    role -> user:string option -> attrs:Auth.user_attributes ->
    (bool, CI_web_templates.Error.t) result;
  acl_github_repos : Repo.t list;       (* Repositories we need info about *)
}

let cookie_key t =
  "__ci_session:" ^ t.web_config.CI_web_templates.name

let can_read_github ~user p attrs =
  try Ok (List.assoc p attrs.Auth.can_read_github)
  with Not_found ->
    match user with
      | Some user when String.is_prefix ~affix:"github:" user ->
        Error (CI_web_templates.Error.logout_needed)
      | _ -> Ok false

let rec matches_acl ~user ~attrs = function
  | `Everyone -> Ok true
  | `Username required -> Ok (Some required = user)
  | `Github_org org -> Ok (List.mem org attrs.Auth.github_orgs)
  | `Can_read project -> can_read_github ~user project attrs
  | `Any xs ->
    let rec aux = function
      | [] -> Ok false
      | x::xs ->
        match matches_acl ~user ~attrs x with
        | Ok false -> aux xs
        | Ok true | Error _ as r -> r
    in
    aux xs

let github_repos_in_policy acl =
  let rec aux acc = function
  | `Can_read project -> Repo.Set.add project acc
  | `Any xs -> List.fold_left aux acc xs
  | `Everyone | `Username _ | `Github_org _ -> acc
  in
  aux Repo.Set.empty acl

let server ~auth ~web_config ~session_backend ~public_address =
  let has_role r ~user ~attrs =
    match r with
    | `Reader -> matches_acl web_config.CI_web_templates.can_read ~user ~attrs
    | `Builder -> matches_acl web_config.CI_web_templates.can_build ~user ~attrs
    | `LoggedIn -> Ok (user <> None)
    | `Admin -> Ok (user = Some "admin")
  in
  let acl_github_repos =
    Repo.Set.union
      (github_repos_in_policy web_config.CI_web_templates.can_read)
      (github_repos_in_policy web_config.CI_web_templates.can_build)
    |> Repo.Set.elements
  in
  let session_backend = Session.connect session_backend in
  let secure_cookies =
    (* Note: we care about the address the user uses, not the scheme we provide.
       e.g. we might be providing HTTP behind an HTTPS proxy - we still want secure
       cookies in that case. *)
    match Uri.scheme public_address with
    | Some "https" -> true
    | Some "http" -> false
    | None -> CI_utils.failf "Missing scheme in public address"
    | Some s -> CI_utils.failf "Unknown scheme %S" s
  in
  { auth; session_backend; web_config; has_role; acl_github_repos; secure_cookies }

let web_config t = t.web_config

class type resource = object
  inherit [Cohttp_lwt.Body.t] Wm.resource
  method content_types_accepted : ((string * Cohttp_lwt.Body.t Wm.acceptor) list, Cohttp_lwt.Body.t) Wm.op
  method content_types_provided : ((string * Cohttp_lwt.Body.t Wm.provider) list, Cohttp_lwt.Body.t) Wm.op
end

class static ~valid ~mime_type dir =
  object(self)
    inherit [Cohttp_lwt.Body.t] Wm.resource

    method content_types_provided rd =
      match mime_type rd.Wm.Rd.uri with
      | None      -> Wm.continue [] rd
      | Some mime -> Wm.continue [mime, self#data] rd

    method content_types_accepted rd =
      Wm.continue [] rd

    method private data rd =
      (* Reload each time to make testing easier. *)
      let ( / ) = Filename.concat in
      let name = Wm.Rd.lookup_path_info_exn "name" rd in
      if Str.string_match valid name 0 then (
        let path = dir / name in
        if Sys.file_exists path then (
          Lwt_io.with_file ~mode:Lwt_io.input path (fun ch -> Lwt_io.read ch) >>= fun body ->
          Wm.continue (`String body) rd
        ) else (
          Log.debug (fun f -> f "Missing static resource %S" name);
          Wm.respond 404 rd ~body:(`String "No such static resource")
        )
      ) else (
        Log.debug (fun f -> f "Invalid static resource name %S" name);
        Wm.respond 404 rd ~body:(`String "Invalid static resource name")
      )
  end

class static_crunch ~mime_type read =
  object(self)
    inherit [Cohttp_lwt.Body.t] Wm.resource

    method content_types_provided rd =
      match mime_type rd.Wm.Rd.uri with
      | None      -> Wm.continue [] rd
      | Some mime -> Wm.continue [mime, self#data] rd

    method content_types_accepted rd =
      Wm.continue [] rd

    method private data rd =
      let dir = Wm.Rd.lookup_path_info_exn "dir" rd in
      let name = Wm.Rd.lookup_path_info_exn "name" rd in
      match read (Printf.sprintf "%s/%s" dir name) with
      | Some data ->
        Wm.continue (`String data) rd
      | None ->
        Log.info (fun f -> f "Missing static resource %S" name);
        Wm.respond 404 rd ~body:(`String "No such static resource")
  end

module Session_data = struct
  type t = {
    csrf_token : string;
    login_redirect : string option;     (* Redirect here when login succeeeds. *)
    username : string option;
    attrs : Auth.user_attributes [@default Auth.empty_attrs];
  } [@@deriving sexp]

  let csrf_token t = t.csrf_token
  let to_string t = Sexplib.Sexp.to_string (sexp_of_t t)
  let of_string s =
    try Ok (t_of_sexp (Sexplib.Sexp.of_string s))
    with ex -> Error ex
end

class virtual resource_with_session t =
  object(self)
    inherit [Cohttp_lwt.Body.t] Wm.resource
    inherit [Cohttp_lwt.Body.t] Session.manager ~cookie_key:(cookie_key t) t.session_backend

    method private session rd =
      let generate_new_session () =
        Log.info (fun f -> f "Generating new session");
        let csrf_token = Base64.encode_string (Nocrypto.Rng.generate 16 |> Cstruct.to_string) in
        let value = { Session_data.csrf_token; username = None; login_redirect = None; attrs = Auth.empty_attrs } in
        self#session_set (Session_data.to_string value) rd >>= fun () ->
        Lwt.return value
      in
      self#session_of_rd rd >>= function
      | Ok None | Error _ -> generate_new_session ()
      | Ok (Some session) ->
        match Session_data.of_string session.Session.value with
        | Ok data -> Lwt.return data
        | Error ex ->
          Log.warn (fun f -> f "Failed to load session data %S: %a"
                       session.Session.value CI_utils.pp_exn ex);
          generate_new_session ()

    method! finish_request rd =
      let rd = self#session_set_hdrs ~path:"/" ~secure:t.secure_cookies rd in
      Wm.continue () rd
  end

let all_roles t ~user ~attrs roles =
  let rec aux = function
    | [] -> Ok true
    | x::xs ->
      match t.has_role ~user ~attrs x with
      | Ok true -> aux xs
      | Ok false | Error _ as r -> r
  in
  aux roles

class virtual protected_page t =
  object(self)
    inherit resource_with_session t

    val mutable authenticated_user = None
    method private authenticated_user = authenticated_user

    method virtual private required_roles : role list

    method! is_authorized rd =
      let roles_needed = self#required_roles in
      self#session rd >>= fun session ->
      match session.Session_data.username with
      | Some _ as username ->
        authenticated_user <- username;
        let attrs = session.Session_data.attrs in
        begin match all_roles t ~user:username ~attrs roles_needed with
        | Ok true -> Wm.continue `Authorized rd
        | Ok false -> Wm.continue (`Redirect (CI_web_templates.Error.(uri permission_denied))) rd
        | Error err -> Wm.continue (`Redirect (CI_web_templates.Error.(uri err))) rd
        end
      | None ->
        match all_roles t ~user:None ~attrs:Auth.empty_attrs roles_needed with
        | Ok true -> Wm.continue `Authorized rd
        | Ok false ->
          let login_redirect =
            match Uri.path rd.Wm.Rd.uri with
            | "/auth/logout" -> None
            | _ -> Some (Uri.path_and_query rd.Wm.Rd.uri)
          in
          let value = {session with Session_data.login_redirect} in
          self#session_set (Session_data.to_string value) rd >>= fun () ->
          Wm.continue (`Redirect (Uri.of_string "/auth/login")) rd
        | Error err -> Wm.continue (`Redirect (CI_web_templates.Error.(uri err))) rd
  end

let check_csrf session_data rd =
  let expected_token = session_data.Session_data.csrf_token in
  match Uri.get_query_param rd.Wm.Rd.uri "CSRFToken" with
  | Some provided_token when provided_token = expected_token -> Wm.continue () rd
  | None -> Wm.respond 403 ~body:(`String "Missing CSRFToken") rd
  | Some provided_token ->
    Log.info (fun f -> f "Expecting CSRFToken %S; got %S" expected_token provided_token);
    Wm.respond 403 ~body:(`String "Incorrect CSRFToken") rd

class virtual post_page t = object(self)
  inherit protected_page t as super

  method! allowed_methods rd =
    Wm.continue [`POST] rd

  method content_types_provided rd =
    Wm.continue [
      "text/html", (fun _ -> assert false);
    ] rd

  method content_types_accepted rd =
    Wm.continue [
      "application/x-www-form-urlencoded", (fun _ -> assert false);
    ] rd

  method! forbidden rd =
    self#session rd >>= fun session_data ->
    check_csrf session_data rd >>= function
    | Wm.Ok (), rd -> super#forbidden rd
    | (Wm.Error _, _) as x -> Lwt.return x
end

class logout_page t = object(self)
  inherit post_page t

  method private required_roles = []

  method! private process_post rd =
    self#session rd >>= fun session_data ->
    let session = {session_data with Session_data.username = None} in
    self#session_set (Session_data.to_string session) rd >>= fun () ->
    Wm.continue true (Wm.Rd.redirect "/" rd)
end

(* This is used to log in before the user database has been configured. *)
class auth_intro t = object(self)
  inherit resource_with_session t

  method! allowed_methods rd =
    Wm.continue [`GET] rd

  method content_types_provided rd =
    Wm.continue [
      "text/html", self#to_html;
    ] rd

  method content_types_accepted rd =
    Wm.continue [] rd

  method private to_html rd =
    let token = Wm.Rd.lookup_path_info_exn "token" rd in
    match Auth.check_setup_token t.auth token with
    | Error msg ->
      Prometheus.Counter.inc_one Metrics.local_login_rejected_total;
      Wm.respond 403 ~body:(`String msg) rd
    | Ok () ->
      Prometheus.Counter.inc_one Metrics.local_login_ok_total;
      self#session rd >>= fun session_data ->
      let session = {session_data with Session_data.username = Some "admin"} in
      self#session_set (Session_data.to_string session) rd >>= fun () ->
      Wm.respond 303 (Wm.Rd.redirect "/auth/setup" rd)
end

class github_callback t = object(self)
  inherit resource_with_session t

  method! allowed_methods rd =
    Wm.continue [`GET] rd

  method content_types_provided rd =
    Wm.continue [
      "text/html", self#to_html;
    ] rd

  method content_types_accepted rd =
    Wm.continue [] rd

  method private to_html rd =
    self#session rd >>= fun session_data ->
    let expected_token = session_data.Session_data.csrf_token in
    let reject msg =
      Prometheus.Counter.inc_one Metrics.github_login_rejected_total;
      Wm.respond 403 ~body:(`String msg) rd
    in
    match Uri.get_query_param rd.Wm.Rd.uri "state" with
    | None -> reject "Missing state"
    | Some provided_token when provided_token <> expected_token ->
      Log.info (fun f -> f "Expecting state %S; got %S" expected_token provided_token);
      reject "Incorrect state"
    | Some _ ->
      match Uri.get_query_param rd.Wm.Rd.uri "code" with
      | None -> reject "Missing code"
      | Some code ->
        Auth.handle_github_callback t.auth ~code ~repos:t.acl_github_repos >>= function
        | Error err -> reject err
        | Ok (user, attrs) ->
            let session = {session_data with Session_data.username = Some user; attrs} in
            self#session_set (Session_data.to_string session) rd >>= fun () ->
            begin match session.Session_data.login_redirect with
              | None -> Lwt.return "/"
              | Some redirect ->
                let value = {session with Session_data.login_redirect = None} in
                self#session_set (Session_data.to_string value) rd >>= fun () ->
                Lwt.return redirect
            end >>= fun redirect ->
            Prometheus.Counter.inc_one Metrics.github_login_ok_total;
            Wm.respond 303 (Wm.Rd.redirect redirect rd)
end

let pp_path =
  Fmt.list ~sep:(Fmt.(const string) ", ") Fmt.string

let callback ~routes _conn request body =
  Metrics.record_request request;
  Prometheus.Summary.time Metrics.response_time_seconds Unix.gettimeofday @@ fun () ->
  Prometheus.Gauge.track_inprogress Metrics.requests_in_progress @@ fun () ->
  Wm.dispatch' routes ~body ~request
  >|= begin function
    | None        -> (`Not_found, Cohttp.Header.init (), `String "Not found", [])
    | Some result -> result
  end
  >>= fun (status, headers, body, path) ->
  Log.info (fun f ->
      let open Cohttp in
      f "%d - %s %s"
        (Code.code_of_status status)
        (Code.string_of_method (Request.meth request))
        (Uri.path (Request.uri request))
    );
  Log.debug (fun f -> f "Webmachine path: %a" pp_path path);
  Metrics.record_response status;
  Server.respond ~headers ~body ~status ()

let serve ~mode ~routes =
  let callback = callback ~routes in
  let http = Server.make ~callback () in
  Conduit_lwt_unix.serve ~mode ~ctx:Conduit_lwt_unix.default_ctx (fun flow ic oc ->
      Lwt.catch
        (fun () -> Server.callback http flow ic oc)
        (fun ex ->
           Log.info (fun f -> f "Error handling HTTP connection: %s" (Printexc.to_string ex));
           Lwt.return ()
        )
    )

class virtual html_page t = object(self)
  inherit protected_page t

  method virtual private render : (CI_web_templates.t -> CI_web_templates.page, Cohttp_lwt.Body.t) Wm.op

  method content_types_provided rd =
    Wm.continue [
      "text/html" , self#to_html;
    ] rd

  method content_types_accepted rd =
    Wm.continue [] rd

  method private to_html rd =
    self#render rd >>= fun (resp, rd) ->
    match resp with
    | Wm.Error _ as e -> Lwt.return (e, rd)
    | Wm.Ok html ->
      let user = self#authenticated_user in
      let body = Fmt.to_to_string (Tyxml.Html.pp ()) (html ~user (web_config t)) in
      Wm.continue (`String body) rd
end

class virtual ['a] form_page t = object(self)
  inherit protected_page t

  method virtual private default : CI_form.State.t Lwt.t
  method virtual private render : csrf_token:string -> CI_form.State.t -> CI_web_templates.t -> CI_web_templates.page
  method virtual private validate : 'a CI_form.Validator.t
  method virtual private process : 'a -> Cohttp_lwt.Body.t Wm.acceptor

  method! allowed_methods rd =
    Wm.continue [`GET; `POST] rd

  method content_types_provided rd =
    Wm.continue [
      "text/html" , self#to_html;
    ] rd

  method content_types_accepted rd =
    Wm.continue [
      "application/x-www-form-urlencoded", (fun _ -> assert false);
    ] rd

  method! private process_post rd =
    self#session rd >>= fun session_data ->
    let expected_token = session_data.Session_data.csrf_token in
    match Uri.get_query_param rd.Wm.Rd.uri "CSRFToken" with
    | None -> Wm.respond 403 ~body:(`String "Missing CSRFToken") rd
    | Some provided_token when provided_token <> expected_token ->
      Log.info (fun f -> f "Expecting CSRFToken %S; got %S" expected_token provided_token);
      Wm.respond 403 ~body:(`String "Incorrect CSRFToken") rd
    | Some _ ->
      match Cohttp.Header.get rd.Wm.Rd.req_headers "content-type" with
      | None -> Wm.respond 403 ~body:(`String "Missing Content-Type header") rd
      | Some content_type ->
        let body = rd.Wm.Rd.req_body in
        Multipart.parse_stream ~stream:(Cohttp_lwt.Body.to_stream body) ~content_type >>= fun parts ->
        Multipart.get_parts parts >>= fun parts ->
        match CI_form.Validator.run self#validate parts with
        | Ok data -> self#process data rd
        | Error state ->
          self#html_of_form state rd >>= fun body ->
          Wm.respond 400 ~body:(`String body) rd

  method private html_of_form state rd =
    self#session rd >|= fun session_data ->
    let csrf_token = Session_data.csrf_token session_data in
    let user = self#authenticated_user in
    let html = self#render ~csrf_token state ~user (web_config t) in
    Fmt.to_to_string (Tyxml.Html.pp ()) html

  method private to_html rd =
    self#default >>= fun state ->
    self#html_of_form state rd >>= fun body ->
    Wm.continue (`String body) rd
end

class auth_setup t =
  object(self)
    inherit [string] form_page t

    method private required_roles = [`Admin]

    method private default = Lwt.return CI_form.State.empty

    method private render = CI_web_templates.auth_setup

    method private validate =
      let open CI_form.Validator in
      get "password" non_empty >>!= fun password ->
      get "password2" (confirm password) >>!= fun () ->
      maybe password

    method private process password rd =
      Auth.initialise_local_users t.auth ~password >>= function
      | Error e -> Wm.respond 400 ~body:(`String e) rd
      | Ok () ->
        self#session rd >>= fun session_data ->
        let session = { session_data with Session_data.
                                       username = None;
                                       attrs = Auth.empty_attrs;
                                       login_redirect = Some "/";
                      } in
        self#session_set (Session_data.to_string session) rd >>= fun () ->
        Wm.respond 303 (Wm.Rd.redirect "/auth/login" rd)
  end

class login_page t = object(self)
  inherit [string] form_page t

  method private required_roles = []

  method private default = Lwt.return CI_form.State.empty

  method private render ~csrf_token state =
    let github = Auth.github_login_url ~csrf_token t.auth in
    let is_configured = Auth.is_configured t.auth in
    CI_web_templates.login_page ?github ~csrf_token state ~is_configured

  method private validate =
    let open CI_form.Validator in
    get "user" non_empty <*> get "password" string >>!= fun (user, password) ->
    match Auth.lookup t.auth ~user ~password with
    | None ->
      Prometheus.Counter.inc_one Metrics.local_login_rejected_total;
      fail "login" ~msg:"Invalid username/password"
    | Some _ ->
      Prometheus.Counter.inc_one Metrics.local_login_ok_total;
      maybe user

  method private process user rd =
    self#session rd >>= fun session_data ->
    let session = {session_data with Session_data.username = Some user} in
    self#session_set (Session_data.to_string session) rd >>= fun () ->
    begin match session.Session_data.login_redirect with
      | None -> Lwt.return "/"
      | Some redirect ->
        let value = {session with Session_data.login_redirect = None} in
        self#session_set (Session_data.to_string value) rd >>= fun () ->
        Lwt.return redirect
    end >>= fun redirect ->
    Wm.continue true (Wm.Rd.redirect redirect rd)
end

class github_auth_settings t = object
  inherit [CI_secrets.github_auth option] form_page t

  method private required_roles = [`Admin]

  method private default =
    Lwt.return @@
      match CI_secrets.get t.auth.Auth.github with
      | None -> CI_form.State.empty
      | Some {CI_secrets.client_id; client_secret = _; callback} ->
        let values = ["client-id", client_id] in
        let values =
          match callback with
          | None -> values
          | Some callback -> ("callback", Uri.to_string callback) :: values
        in
        CI_form.State.of_values values

  method private validate =
    let open CI_form.Validator in
    get "client-id" (optional string) <*> get "client-secret" (optional string) <*> get "callback" (optional uri)
    >>!= function
    | (None, None), None -> maybe None
    | (Some client_id, Some client_secret), callback ->
      maybe (Some { CI_secrets.client_id; client_secret; callback })
    | (None, Some _), _ -> fail "client-id" ~msg:"Client ID must be set if the secret is"
    | (None, _), Some _ -> fail "client-id" ~msg:"Client ID must be set if the callback is"
    | (Some _, None), _ -> fail "client-secret" ~msg:"Client Secret must be provided if Client ID is"

  method private process config rd =
    CI_secrets.set t.auth.Auth.github config >>= fun () ->
    Wm.continue true (Wm.Rd.redirect "/auth/login" rd)

  method private render = CI_web_templates.Settings.github_auth
end

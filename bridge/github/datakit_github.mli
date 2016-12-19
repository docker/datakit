(** Main object types used by the GitHub bridge. *)

(** {1 Printable Sets} *)

(** Pretty-printable {!Set.OrderedType}. *)
module type ELT = sig
  include Set.OrderedType
  val pp: t Fmt.t
end

(** Pretty-printable {!Set.S}. *)
module type SET = sig
  include Asetmap.Set.S
  val pp: t Fmt.t
end

(** Pretty-printable {!Map.S}. *)
module type MAP = sig
  include Asetmap.Map.S
  val pp: 'a Fmt.t -> 'a t Fmt.t
end

module Set (E: ELT): SET with type elt = E.t
(** [Set] is similar to {!Set.Make} but for pretty-printable sets. *)

(** {1 Data-model} *)

module Status_state: sig

  type t = [ `Error | `Pending | `Success | `Failure ]
  (** The type for status states. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for status states. *)

  val to_string: t -> string
  (** [to_string v] is the string represenation of [v]. *)

  val of_string: string -> t option
  (** [of_string s] is the value v such that [of_string s] is [Some
      v]. *)

end

module Org: sig

  type t = private string
  (** The type for GitHub organisations. *)

  val v: string -> t
  (** [v org] is the organisation [org]. *)

  val pp: string Fmt.t
  (** [pp] is the pretty-printer for organisations. *)

  val compare: string -> string -> int
  (** [compare] compares organisations. *)

  module Set: SET with type elt = t

end

module Repo: sig

  type t = private { user: string; repo: string }
  (** The type for Github repositories. *)

  type state = [`Monitored | `Ignored]
  (** The type for repository state. *)

  val v : user:string -> repo:string -> t
  (** [v user string] will create a fresh {!t}. *)

  val of_string: string -> t option
  (** [of_string s] parses strings of the form [":user/:repo"]. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for Github repositories. *)

  val compare: t -> t -> int
  (** [compare] compares repositories.*)

  val pp_state: state Fmt.t
  (** [pp_state] is the pretty-printer for repository state. *)

  module Set: SET with type elt = t
  (** Sets of repositories. *)

  module Map: MAP with type key = t
  (** Maps of repositories. *)

end

module Commit: sig

  type t = private { repo: Repo.t; hash: string }
  (** The type for commits. *)

  val v : Repo.t -> string -> t
  (** [v repo id] builds a fresh {!t} with [repo] and [id]. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for commits. *)

  val pp_hash: string Fmt.t
  (** [pp_hash] is the pretty-printer for commit hashes which just
      show the first 8 characters of the hash. *)

  val compare: t -> t -> int
  (** [compare] compares commits. *)

  val repo: t -> Repo.t
  (** [repo t] is [t]'s repository. *)

  val hash: t -> string
  (** [hash t] is [t]'s SHA1. *)

  val equal: t -> t -> bool
  (** [equal] is the equality functions for commits. *)

  module Set: sig
    include SET with type elt = t
    val repos: t -> Repo.Set.t
  end
  (** Sets of commits. *)

end

module PR: sig

  (** The type for pull-requests values. *)
  type t = private {
    head: Commit.t;
    number: int;
    state: [`Open | `Closed];
    title: string;
    base: string;
  }

  val v: ?state:[`Open|`Closed] -> title:string -> ?base:string ->
    Commit.t -> int -> t
  (** [v c n ~title] is the pull-request [n] with head commit [c] and
      title [title]. If [base] is not set, use ["master"]. If [state]
      is not set, use [`Open]. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for pull-request values. *)

  val compare: t -> t -> int
  (** [compare] compares pull requests. *)

  type id = Repo.t * int
  (** The type for commit ids. *)

  val pp_id: id Fmt.t
  (** [pp_id] is the pretty-printer for PR ids. *)

  val repo: t -> Repo.t
  (** [repo t] is [t]'s repostiory. *)

  val id: t -> id
  (** [id t] is [t]'s ID. *)

  val commit: t -> Commit.t
  (** [commit t] is [t]'s commit. *)

  val commit_hash: t -> string
  (** [commit_hash t] is the SHA1 of [t]'s commit. *)

  val number: t -> int
  (** [number t] is [t]'s number. *)

  val state: t -> [`Open | `Closed]
  (** [state t] is [t]'s state. *)

  val close: t -> t
  (** [close t] is [t] with [state t] set to [`Closed]. *)

  val state_of_string: string -> [`Open | `Closed] option
  (** [string_of_state str] is [Some s] if there exists a state [s]
      such that [state_of_string s] is [str]. Otherwise it is
      [None]. *)

  val string_of_state: [`Open | `Closed] -> string
  (** [state_of_string s] is [s]'s string representation. *)

  val title: t -> string
  (** [title t] is [t]'s title. *)

  val same_id: t -> t -> bool
  (** [same_id x y] is true if [x] and [y] have the same ID. *)

  val compare_id: id -> id -> int
  (** [compare_id x y] compare the pull-request IDs [x] and [y]. *)

  module Set: sig
    include SET with type elt = t
    val repos: t -> Repo.Set.t
    val commits: t -> Commit.Set.t
    val map: (elt -> elt) -> t -> t
  end
  (** Sets of pull requests. *)

  module Index: MAP with type key = id
  (** Maps indexed by pull-request IDs. *)

  val index: Set.t -> t Index.t Repo.Map.t
  (** [index s] indexes [s] by pull-request IDs. *)

end

module Status: sig

  type context = string list
  (** The type build build status contexts. ["ci/datakit"] is stored
      as ["ci"; "datakit"]. *)

  type t = private {
    commit: Commit.t;
    context: context;
    url: Uri.t option;
    description: string option;
    state: Status_state.t;
  }
  (** The type for status values. *)

  val v: ?description:string -> ?url:Uri.t ->
    Commit.t -> string list -> Status_state.t -> t
  (** [v c n] is the status with commit [c] and name [n]. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for status values. *)

  val pp_context: context Fmt.t
  (** [pp_context] pretty-prints build status' contexts. *)

  type id = Commit.t * context
  (** The type for build-status IDs. *)

  val pp_id: id Fmt.t
  (** [pp_id] is the pretty-printer for build-status IDs. *)

  val id: t -> id
  (** [id t] is [t]'s ID. *)

  val compare_id: id -> id -> int
  (** [compare_id] compares build status IDs. *)

  val context: t -> context
  (** [context t] is [t]'s context. *)

  val state: t -> Status_state.t
  (** [state t] is [t]'s state. *)

  val description: t -> string option
  (** [description t] is [t]'s description. *)

  val url: t -> Uri.t option
  (** [url t] is [t]'s target URL. *)

  val repo: t -> Repo.t
  (** [repo t] is [t]'s repository. *)

  val commit: t -> Commit.t
  (** [commit t] is [t]'s commit. *)

  val commit_hash: t -> string
  (** [commit_hash t] is [t]'s commit SHA1. *)

  val same_id: t -> t -> bool
  (** [same_id x y] is true if [x] and [y] have the same ID. *)

  val compare: t -> t -> int
  (** [compare] is the comparison function for build status. *)

  module Set: sig
    include SET with type elt = t
    val repos: t -> Repo.Set.t
    val commits: t -> Commit.Set.t
  end
  (** Sets of build status. *)

  module Index: MAP with type key = id
  (** Maps indexed by build status IDs. *)

  val index: Set.t -> t Index.t Repo.Map.t
  (** [index s] indexes [s] by build status IDs. *)

end

module Ref: sig

  type name = string list
  (** The type for reference names. ["heads/master"] is represented as
      ["heads";"master"]. *)

  type t = private {
    head: Commit.t;
    name: string list;
  }
  (** The type for Git references. *)

  val v : Commit.t -> name -> t
  (** [v head name] is a fresh {!t} with the [head] commit and
      [name]. [name] should only contain alpha-numeric character,
      ['_'] and ['-']. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for references. *)

  val pp_name: name Fmt.t
  (** [pp_name ["a";"b";"c"]] is ["a/b/c"] *)

  val compare: t -> t -> int
  (** [compare] compares Git references. *)

  type id = Repo.t * name
  (** The type for Git reference IDs. *)

  val pp_id: id Fmt.t
  (** [pp_id] is the pretty-printer for Git reference IDs. *)

  val id: t -> id
  (** [id t] is [t]'s ID. *)

  val name: t -> name
  (** [name t] is [t]'s name. *)

  val repo: t -> Repo.t
  (** [repo t] is [t]'s repository. *)

  val commit: t -> Commit.t
  (** [commit t] is [t]'s commit. *)

  val commit_hash: t -> string
  (** [commit_hash t] is [t]'s commit SHA1. *)

  val same_id: t -> t -> bool
  (** [same_id x y] is true if [x] and [y] have the same ID. *)

  val compare_id: id -> id -> int
  (** [compare_id x y] compares the Git reference IDs [x] and [y]. *)

  module Set: sig
    include SET with type elt = t
    val repos: t -> Repo.Set.t
    val commits: t -> Commit.Set.t
  end
  (** Sets of Git references. *)

  type event = [`Created of t | `Updated of t | `Removed of id]
  (** The type for reference events' state. *)

  val pp_event: event Fmt.t
  (** [pp_event] is the pretty-printer for reference events' state.*)

  module Index: MAP with type key = id
  (** Maps indexed by Git reference IDs. *)

  val index: Set.t -> t Index.t Repo.Map.t
  (** [index s] indexes [s] by Git reference IDs. *)

end

module Event: sig

  (** The type for event values. *)
  type t =
    | Repo of (Repo.state * Repo.t)
    | PR of PR.t
    | Status of Status.t
    | Ref of Ref.event
    | Other of (Repo.t * string)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for event values. *)

  val of_repo: Repo.state -> Repo.t -> t
  val of_pr: PR.t -> t
  val of_status: Status.t -> t
  val of_ref: Ref.event -> t
  val of_other: Repo.t -> string -> t

  val repo: t -> Repo.t
  (** [repo t] is [t]'s repository. *)

end

module Elt: sig

  type t = [
    | `Org of Org.t
    | `Repo of Repo.t
    | `Commit of Commit.t
    | `PR of PR.t
    | `Status of Status.t
    | `Ref of Ref.t
  ]

  val pp: t Fmt.t
  val compare: t -> t -> int

  type id = [
    | `Org of Org.t
    | `Repo of Repo.t
    | `Commit of Commit.t
    | `PR of PR.id
    | `Status of Status.id
    | `Ref of Ref.id
  ]

  val id: t -> id
  val pp_id: id Fmt.t
  val compare_id: id -> id -> int

  module Set: SET with type elt = t
  module IdSet: sig
    include SET with type elt = id
    val of_repos: Repo.Set.t -> t
    val of_prs: PR.Set.t -> t
    val of_refs: Ref.Set.t -> t
  end

end

module Snapshot: sig

  (** {1 GitHub snapshot} *)

  type t
  (** The type for GitHub snapshot. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for snapshots. *)

  val empty: t
  (** The empty snapshot. *)

  val is_empty: t -> bool
  (** [is_empty t] is true if [t] is {!empty}. *)

  val v: orgs:Org.Set.t ->
    repos:Repo.Set.t -> commits:Commit.Set.t -> status:Status.Set.t ->
    prs:PR.Set.t -> refs:Ref.Set.t -> t
  (** [v ~orgs ~repos ~commits ~status ~prs ~refs] is a new snapshot
      [t] with orgnasiations [orgs], repositories [reps], commits
      [commits], pull-requests [prs], build statuses [status] and Git
      references [refs]. *)

  val compare: t -> t -> int
  (** [compare] is the comparison function for snapshots. *)

  val union: t -> t -> t
  (** [union x y] is the union of the snapshots [x] and [y]. *)

  val prune: t -> t
  (** [prune t] is [t] where all the objects related to closed PRs
      have been removed. *)

  (** {1 Diffs} *)

  type diff
  (** The type for snapshot diffs. *)

  val diff: t -> t -> diff
  (** [diff x y] is the difference between [x] and [y]. *)

  (** {1 Elements} *)

  val elts: t -> Elt.Set.t
  (** [elts t] is the collection of elements of [t]. *)

  val orgs: t -> Org.Set.t
  (** [org t] are [t]'s organisations. *)

  val repos: t -> Repo.Set.t
  (** [repos t] are [t]'s repositories. *)

  val prs: t -> PR.Set.t
  (** [prs t] are [t]'s pull-requests. *)

  val commits: t -> Commit.Set.t
  (** [commits t] are [t]'s commits. *)

  val status: t -> Status.Set.t
  (** [status t] are [t]'s build status. *)

  val refs: t -> Ref.Set.t
  (** [refs t] are [t]'s Git references. *)

  val with_elt: Elt.t -> t -> t
  (** [with_elt e t] it [t] with the element [e] added. *)

  val with_elts: Elt.Set.t -> t -> t
  (** [with_elts] is like {!with_elt} but for a collection of
      elements. *)

  val find: Elt.id -> t -> Elt.t option
  (** [find id t] finds the element with ID [id] in [t]. *)

end

module Diff: sig

  (** {1 GitHub Diffs} *)

  type t = Snapshot.diff
  (** The type for differences between GitHub states. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for diffs. *)

  val compare: t -> t -> int
  (** [compare_diff] is the comparison function for diffs. *)

  val commit_message: t -> string
  (** [commit_message d] is the commit message corresponding to the
      diff [d]. *)

  val empty: t
  (** [empty] is the empty diff. *)

  val is_empty: t -> bool
  (** [is_empty d] is true if [d] is empty. *)

  val update: t -> Elt.Set.t
  (** [update d] are the elements in [d] which needs to be added or
      updated. *)

  val remove: t -> Elt.IdSet.t
  (** [remove d] are the elements in [d] which needs to be deleted. *)

  val apply: t -> Snapshot.t -> Snapshot.t
  (** [snapsho d s] applies [d] on top of the snapshot [s]. *)

  val with_update: Elt.t -> t -> t
  (** [with_update e d] is [d] augmented with the update of [e]. *)

  val with_remove: Elt.id -> t -> t
  (** [with_remove e d] is [d] augmented with the removal of [e]. *)

end


(** {1 API} *)


(** API capabilities, used to restrict the scope of an
    {!API.token}. *)
module Capabilities: sig

  type t
  (** The type for API capabilities. *)

  val pp: t Fmt.t
  (** [pp] is the pretty-printer for capabilities. *)

  val equal: t -> t -> bool
  (** [equal] equalizes capabilities. *)

  val parse: string -> [ `Error of string | `Ok of t ]
  (** [parse] is the parses capabilites, such that [parse
      (Fmt.to_to_string pp x) = `Ok x]. *)

  type op = [`Read | `Write | `Excl]
  (** The type for API operations.
      {ul
      {- [`Read] allows the bridge to read the corresponding kind of
         GitHub resources}
      {- [`Write] allows the bridge to update the corresponding kind
         of resource.}
      {- [`Excl] means that the bridge has exclusive write access
         to the corresponding GitHub resource. In particular, this
         means that when the bridge is disconnect/reconnect it will
         always try to update GitHub to match with the current state
         of its local resources and it will revert any changes made
         by other GitHub users on this kind of resources.}
      ul}
  *)

  val pp_op: op Fmt.t
  (** [pp_op] is the pretty-printer for resource operations. *)

  type resource = [
    | `Org of string
    | `Repo of string list
    | `PR
    | `Commit
    | `Status of string list
    | `Ref
    | `Webhook
  ]
  (** The type for API resources. *)

  val pp_resource: resource Fmt.t
  (** [pp_resource] is the pretty-printer for resources. *)

  val none: t
  (** [none] is the capability to do nothing. *)

  val all: t
  (** [all] is the capability to do everything. *)

  val allow: t -> op -> [`Default | resource] -> t
  (** [allow t o r] is [t] with the capability to do API calls of type
      [o] to the kind of resource [r]. *)

  val disallow: t -> op -> [`Default | resource] -> t
  (** [disallow t o r] is [t] without the capability to do API calls
      of type [o] to the kind of resource [r]. *)

  val check: t -> op -> resource -> bool
  (** [check t o r] is true if [t] is allowed to to [o] on the kind of
      resource [r]. *)

  val filter_diff: t -> op -> Snapshot.diff -> Snapshot.diff
  (** [filter_diff t op d] filters the diff [d] to only apply the
      subset of operations [op] over the capabilities defined by
      [t]. *)

end

(** Signature for the GitHub API. *)
module type API = sig

  (** {1 API tokens} *)
  type token
  (** The type for API tokens. *)

  type 'a result = ('a, string) Result.result Lwt.t
  (** The type for results. *)

  val user_exists: token -> user:string -> bool result
  (** [exist_user t ~user] is true iff [user] exists. *)

  val repo_exists: token -> Repo.t -> bool result
  (** [exists_repo t r] is true iff the repository [r] exists. *)

  val repos: token -> user:string -> Repo.t list result
  (** [repos t ~user] is the list of repositories owned by user
      [user]. *)

  val status: token -> Commit.t -> Status.t list result
  (** [status t c] returns the list of status attached to the commit
      [c]. *)

  val set_status: token -> Status.t -> unit result
  (** [set_status t s] updates [Status.commit s]'s status with [s]. *)

  val set_ref: token -> Ref.t -> unit result
  (** [set_ref t r] updates the reference named [Ref.name r] with
      [r]. *)

  val remove_ref: token -> Repo.t -> string list -> unit result
  (** [remove_ref t n] removes the reference named [n]. *)

  val set_pr: token -> PR.t -> unit result
  (** [set_pr t pr] updates the PR number [PR.number pr] with [pr]. *)

   val prs: token -> Repo.t -> PR.t list result
  (** [prs t r] is the list of open pull-requests for the repo [r]. *)

  val pr: token -> PR.id -> PR.t option result
  (** [pr t id] is the contents of the pull request whose ID Is
      [id]. *)

  val refs: token -> Repo.t -> Ref.t list result
  (** [refs t r] is the list of references for the the repo [r]. *)

  val ref: token -> Ref.id -> Ref.t option result
  (** [ref t id] is the Git reference whose ID is [id]. *)

  val events: token -> Repo.t -> Event.t list result
  (** [event t r] is the list of events attached to the repository
      [r]. Note: can be slow/costly if multiple pages of events. *)

  module Webhook: sig

    type t
    (** The type for the webhook server state. *)

    val v: token -> Uri.t -> t
    (** [v tok uri] is the webhook server state configured to listen
        for incoming webhook events to the public address [uri] and
        using the token [tok] to perform GitHub API calls. The
        function [f] will be called everytime a new event is
        received. *)

    val run: t -> unit Lwt.t
    (** [run t] is a blocking lwt thread which runs the webook
        listener. *)

    val repos: t -> Repo.Set.t
    (** The list of watched repository. *)

    val watch: t -> Repo.t -> unit Lwt.t
    (** [watch t r] makes [t] watch the repo [r]. *)

    val watch_org: t -> Org.t -> unit Lwt.t
    (** [watch_org t o] watches all the repositories in [o] using
        global organisation hooks. *)

    val events: t -> Event.t list
    (** [events t] is the list of events stored in [t]. *)

    val wait: t -> unit Lwt.t
    (** [wait t] waits for new events to be available. *)

    val clear: t -> unit
    (** [clear t] clears the list of events stored in [t]. *)

  end

end

(** API State: TODO find a better name? *)
module State (API: API): sig

  (** {1 Token} *)

  type token
  (** The type for state token. *)

  val token: API.token -> Capabilities.t -> token
  (** [token t c] is the token using the GitHub API token [t] limited
      by the capabilities [c]. *)

  val capabilities: token -> Capabilities.t
  (** [capabilities t] is the token [t]'s capabilities. *)

  val with_capabilities: Capabilities.t -> token -> token
  (** [with_capabilities c t] is [t] with the capabilities [c]. *)

  (** {1 Synchronisation} *)

  val import: token -> Snapshot.t -> Elt.IdSet.t -> Snapshot.t Lwt.t
  (** [import token t r] imports the state of GitHub for the elements
      in [r] into [t]. API calls use the token [token]. *)

  val apply: token -> Diff.t -> unit Lwt.t
  (** [apply token d] applies the snapshot diff [d] as a series of
      GitHub API calls, using the token [token]. *)

  (** {1 Webhooks} *)

  val add_repo_webhooks:
    token -> watch:(Repo.t -> unit Lwt.t) -> Repo.Set.t -> unit Lwt.t
  (** [add_repo_webhooks t rs] adds webhooks for the repositories
      [rs]. *)

  val add_org_webhooks:
    token -> watch:(Org.t -> unit Lwt.t) -> Org.Set.t -> unit Lwt.t
  (** [add_org_webhooks t os] adds webhooks for the organisations
      [os]. *)

  val import_webhook_events:
    token -> events:(unit ->  Event.t list) -> Snapshot.t -> Snapshot.t Lwt.t
  (** [import_webhook_events t ~events s] applies [events ()] on top
      of [s]. Note: it ensure that all the metadata are correctly
      updated by inserting (possibly) missing events in the mix. For
      instance, GitHub never sends {{!Event.Status}status} events, so
      [import_events] has to reconstruct them. *)

end

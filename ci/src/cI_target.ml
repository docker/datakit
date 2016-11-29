open Astring
open Asetmap

module ID = struct
  type t = [ `PR of int | `Ref of string ]

  let pp f = function
    | `PR x -> Fmt.pf f "prs/%d" x
    | `Ref x -> Fmt.string f x

  let compare a b =
    match a, b with
    | `PR a , `PR b -> compare a b
    | `Ref a, `Ref b -> String.compare a b
    | _ -> compare a b
end

module ID_Set = Set.Make(ID)

module Full = struct
  type t = CI_projectID.t * ID.t

  let project = fst
  let id = snd

  let parse s =
    let ( >>= ) x f =
      match x with
      | `Error _ as e -> e
      | `Ok x -> f x
    in
    let slash name s =
      match String.cut ~sep:"/" s with
      | None -> `Error (Fmt.strf "Missing %s/ at start of %S" name s)
      | Some (a, b) -> `Ok (a, b)
    in
    let parse_target = function
      | ("heads" | "tags") as ref_type, ref ->
        begin match Datakit_path.of_string ref with
          | Ok path -> `Ok (`Ref (Fmt.strf "%s/%a" ref_type Datakit_path.pp path))
          | Error msg -> `Error msg
        end
      | "prs", id ->
        begin match String.to_int id with
          | Some id -> `Ok (`PR id)
          | None -> `Error (Fmt.strf "Invalid PR number %S" id)
        end
      | ty, _ -> `Error (Fmt.strf "Bad target type %S (should be heads/tags/prs)" ty)
    in
    slash "user" s >>= fun (user, s) ->
    slash "project" s >>= fun (project, s) ->
    slash "ref_type" s >>= fun (ref_type, ref) ->
    parse_target (ref_type, ref) >>= fun target ->
    `Ok (CI_projectID.v ~user ~project, target)

  let pp f (project, target) =
    Fmt.pf f "%a/%a" CI_projectID.pp project ID.pp target

  let arg = parse, pp

  let map_of_list xs =
    let map = ref CI_projectID.Map.empty in
    xs |> List.iter (fun (p, target) ->
        let old_targets = CI_projectID.Map.find p !map |> CI_utils.default ID_Set.empty in
        map := !map |> CI_projectID.Map.add p (ID_Set.add target old_targets)
      );
    !map
end

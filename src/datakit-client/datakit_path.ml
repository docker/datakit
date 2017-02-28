open Result

module Step = struct
  type t = string

  let of_string = function
    | "" | "." | ".." as x -> Error (Fmt.strf "Invalid path component %S" x)
    | x when String.contains x '/' -> Error (Fmt.strf "'/' in path step %S" x)
    | x -> Ok x

  let of_string_exn s =
    match of_string s with
    | Ok x -> x
    | Error msg -> raise (Invalid_argument msg)

  let to_string x = x

  let compare = String.compare

  let pp = Fmt.string
end

type t = Step.t list

let empty = []

let of_steps steps =
  let rec aux = function
    | [] -> Ok steps
    | x :: xs ->
      match Step.of_string x with
      | Ok _ -> aux xs
      | Error _ as e -> e in
  aux steps

let of_string path =
  of_steps (Astring.String.cuts ~sep:"/" path)

let of_string_exn path =
  match of_string path with
  | Ok x -> x
  | Error msg -> raise (Invalid_argument msg)

let pp = Fmt.(list ~sep:(const string "/") string)

let of_steps_exn steps =
  match of_steps steps with
  | Ok x -> x
  | Error msg ->
    raise (Invalid_argument (Fmt.strf "Bad path %a: %s" pp steps msg))

let unwrap x = x

let to_hum = Fmt.to_to_string pp

let compare = compare

let dirname t = match List.rev t with
  | []   -> []
  | _::t -> List.rev t

let basename t = match List.rev t with
  | []   -> None
  | h::_ -> Some h

let pop = function
  | [] -> None
  | x::xs ->
    let rec aux dir this = function
      | [] -> Some (List.rev dir, this)
      | x::xs -> aux (this :: dir) x xs
    in
    aux [] x xs

module Set = Set.Make(struct type t = string list let compare = compare end)
module Map = Map.Make(struct type t = string list let compare = compare end)

module Infix = struct

  let ( / ) path s =
    match Step.of_string s with
    | Ok s -> path @ [s]
    | Error msg -> raise (Invalid_argument msg)

  let ( /@ ) = ( @ )

end

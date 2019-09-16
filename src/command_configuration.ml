open Core

open Language

(* skip or continue directory descent *)
type 'a next =
  | Skip of 'a
  | Continue of 'a

let fold_directory ?(sorted=false) root ~init ~f =
  let rec aux acc absolute_path depth =
    if Sys.is_file absolute_path = `Yes then
      match f acc ~depth ~absolute_path ~is_file:true with
      | Continue acc
      | Skip acc -> acc
    else if Sys.is_directory absolute_path = `Yes then
      match f acc ~depth ~absolute_path ~is_file:false with
      | Skip acc -> acc
      | Continue acc ->
        let dir_contents =
          if Option.is_some (Sys.getenv "COMBY_TEST") || sorted then
            Sys.ls_dir absolute_path
            |> List.sort ~compare:String.compare
            |> List.rev
          else
            Sys.ls_dir absolute_path
        in
        List.fold dir_contents ~init:acc ~f:(fun acc subdir ->
            aux acc (Filename.concat absolute_path subdir) (depth + 1))
    else
      acc
  in
  (* The first valid ls_dir happens at depth 0 *)
  aux init root (-1)

let parse_source_directories ?(file_filters = []) exclude_directory_prefix target_directory directory_depth =
  let max_depth = Option.value directory_depth ~default:Int.max_value in
  let f acc ~depth ~absolute_path ~is_file =
    if depth > max_depth then
      Skip acc
    else
      begin
        if is_file then
          match file_filters with
          | [] ->
            Continue (absolute_path::acc)
          | suffixes when List.exists suffixes ~f:(fun suffix -> String.is_suffix ~suffix absolute_path) ->
            Continue (absolute_path::acc)
          | _ ->
            Continue acc
        else
          begin
            if String.is_prefix (Filename.basename absolute_path) ~prefix:exclude_directory_prefix then
              Skip acc
            else
              Continue acc
          end
      end
  in
  fold_directory target_directory ~init:[] ~f

let read filename =
  In_channel.read_all filename
  |> fun template ->
  String.chop_suffix template ~suffix:"\n"
  |> Option.value ~default:template

let parse_template_directories paths =
  let parse_directory path =
    let read_optional filename =
      match read filename with
      | content -> Some content
      | exception _ -> None
    in
    match read_optional (path ^/ "match") with
    | None ->
      Format.eprintf "WARNING: Could not read required match file in %s@." path;
      None
    | Some match_template ->
      let rule = read_optional (path ^/ "rule") in
      let rule =
        match Option.map rule ~f:Rule.create with
        | None -> None
        | Some Ok rule -> Some rule
        | Some Error error ->
          Format.eprintf "Rule parse error: %s@." (Error.to_string_hum error);
          exit 1
      in
      let rewrite_template = read_optional (path ^/ "rewrite") in
      Specification.create ~match_template ?rule ?rewrite_template ()
      |> Option.some
  in
  let f acc ~depth:_ ~absolute_path ~is_file =
    let is_leaf_directory absolute_path =
      not is_file &&
      Sys.ls_dir absolute_path
      |> List.for_all ~f:(fun path -> Sys.is_directory (absolute_path ^/ path) = `No)
    in
    if is_leaf_directory absolute_path then
      match parse_directory absolute_path with
      | Some spec -> Continue (spec::acc)
      | None -> Continue acc
    else
      Continue acc
  in
  List.concat_map paths ~f:(fun path -> fold_directory path ~sorted:true ~init:[] ~f)

type output_options =
  { color : bool
  ; json_pretty : bool
  ; json_lines : bool
  ; json_only_diff : bool
  ; file_in_place : bool
  ; diff : bool
  ; stdout : bool
  ; substitute_in_place : bool
  ; count : bool
  }

type anonymous_arguments =
  { match_template : string
  ; rewrite_template : string
  ; file_filters : string list option
  }

type user_input_options =
  { rule : string
  ; stdin : bool
  ; specification_directories : string list option
  ; anonymous_arguments : anonymous_arguments option
  ; file_filters : string list option
  ; zip_file : string option
  ; match_only : bool
  ; target_directory : string
  ; directory_depth : int option
  ; exclude_directory_prefix : string
  }

type run_options =
  { sequential : bool
  ; verbose : bool
  ; match_timeout : int
  ; number_of_workers : int
  ; dump_statistics : bool
  ; substitute_in_place : bool
  }

type user_input =
  { input_options : user_input_options
  ; run_options : run_options
  ; output_options : output_options
  }

type input_source =
  | Stdin
  | Zip
  | Directory

module Printer = struct

  type printable_result =
    | Matches of
        { source_path : string option
        ; matches : Match.t list
        }
    | Replacements of
        { source_path : string option
        ; replacements : Replacement.t list
        ; result : string
        ; source_content : string
        }

  type t = printable_result -> unit

  module Match : sig

    type match_only_kind =
      | Colored
      | Count

    type match_output =
      | Json_lines
      | Json_pretty
      | Match_only of match_only_kind

    val convert : output_options -> match_output

    val print : match_output -> string option -> Match.t list -> unit

  end = struct

    type match_only_kind =
      | Colored
      | Count

    type match_output =
      | Json_lines
      | Json_pretty
      | Match_only of match_only_kind

    let convert output_options =
      match output_options with
      | { json_pretty = true; json_lines = true; _ }
      | { json_pretty = true; json_lines = false; _ } -> Json_pretty
      | { json_pretty = false; json_lines = true; _ } -> Json_lines
      | { count = true; _ } -> Match_only Count
      | _ -> Match_only Colored

    let print (match_output : match_output) source_path matches =
      let ppf = Format.std_formatter in
      match match_output with
      | Json_lines -> Format.fprintf ppf "%a" Match.pp_json_lines (source_path, matches)
      | Json_pretty -> Format.fprintf ppf "%a" Match.pp_json_pretty (source_path, matches)
      | Match_only _ -> Format.fprintf ppf "%a" Match.pp_match_count (source_path, matches)

  end

  module Rewrite : sig

    type json_kind =
      | Everything
      | Only_diff

    type substitution_kind =
      | Newline_separated
      | In_place

    type diff_kind =
      | Plain
      | Colored

    type output_format =
      | Overwrite_file
      | Stdout
      | Diff of diff_kind
      | Json_lines of json_kind
      | Json_pretty of json_kind
      | Match_only

    type replacement_output =
      { output_format : output_format
      ; substitution_kind : substitution_kind
      }

    val convert : output_options -> replacement_output

    val print : replacement_output -> string option -> Replacement.t list -> string -> string -> unit

  end = struct

    type diff_kind =
      | Plain
      | Colored

    type json_kind =
      | Everything
      | Only_diff

    type substitution_kind =
      | Newline_separated
      | In_place

    type output_format =
      | Overwrite_file
      | Stdout
      | Diff of diff_kind
      | Json_lines of json_kind
      | Json_pretty of json_kind
      | Match_only

    type replacement_output =
      { output_format : output_format
      ; substitution_kind : substitution_kind
      }

    let convert output_options : replacement_output =
      let output_format =
        match output_options with
        | { file_in_place = true; _ } -> Overwrite_file
        | { stdout = true; _ } -> Stdout
        | { json_pretty = true; file_in_place = false; json_only_diff; _ } ->
          if json_only_diff then
            Json_pretty Only_diff
          else
            Json_pretty Everything
        | { json_lines = true; file_in_place = false; json_only_diff; _ } ->
          if json_only_diff then
            Json_lines Only_diff
          else
            Json_lines Everything
        | { diff = true; color = false; _ } ->
          Diff Plain
        | { color = true; _ }
        | _ ->
          Diff Colored
      in
      if output_options.substitute_in_place then
        { output_format; substitution_kind = In_place }
      else
        { output_format; substitution_kind = Newline_separated }

    let print { output_format; substitution_kind } path replacements replacement_content source_content =
      let open Replacement in
      let ppf = Format.std_formatter in
      let output_string =
        match substitution_kind with
        | Newline_separated ->
          List.rev_map replacements ~f:(fun { replacement_content; _ } -> replacement_content)
          |> String.concat ~sep:"\n"
          |> Format.sprintf "%s\n"
        | In_place ->
          replacement_content
      in
      match output_format with
      | Stdout ->
        Format.fprintf ppf "%s" output_string
      | Overwrite_file ->
        begin
          match path with
          | Some path -> Out_channel.write_all path ~data:output_string
          (* This should be impossible since we checked in validate_errors. Leaving the code path explicit. *)
          | None -> failwith "Error: could not write to file."
        end
      | Json_pretty Everything ->
        let diff = Diff_configuration.get_diff Plain path source_content output_string in
        let print diff = Format.fprintf ppf "%a@." Replacement.pp_json_pretty (path, replacements, replacement_content, diff, false) in
        Option.value_map diff ~default:() ~f:(fun diff -> print (Some diff))
      | Json_pretty Only_diff ->
        let diff = Diff_configuration.get_diff Plain path source_content output_string in
        let print diff = Format.fprintf ppf "%a@." Replacement.pp_json_pretty (path, replacements, output_string, diff, true) in
        Option.value_map diff ~default:() ~f:(fun diff -> print (Some diff))
      | Json_lines Everything ->
        let diff = Diff_configuration.get_diff Plain path source_content output_string in
        let print diff = Format.fprintf ppf "%a@." Replacement.pp_json_line (path, replacements, output_string, diff, false) in
        Option.value_map diff ~default:() ~f:(fun diff -> print (Some diff))
      | Json_lines Only_diff ->
        let diff = Diff_configuration.get_diff Plain path source_content output_string in
        let print diff = Format.fprintf ppf "%a@." Replacement.pp_json_line (path, replacements, output_string, diff, true) in
        Option.value_map diff ~default:() ~f:(fun diff -> print (Some diff))
      | Diff Plain ->
        let diff = Diff_configuration.get_diff Plain path source_content output_string in
        Option.value_map diff ~default:() ~f:(fun diff -> Format.fprintf ppf "%s@." diff)
      | Diff Colored ->
        let diff = Diff_configuration.get_diff Colored path source_content output_string in
        Option.value_map diff ~default:() ~f:(fun diff -> Format.fprintf ppf "%s@." diff)
      | Match_only ->
        let diff = Diff_configuration.get_diff Match_only path output_string source_content in
        Option.value_map diff ~default:() ~f:(fun diff -> Format.fprintf ppf "%s@." diff)
  end
end

type t =
  { sources : Command_input.t
  ; specifications : Specification.t list
  ; file_filters : string list option
  ; exclude_directory_prefix : string
  ; run_options : run_options
  ; output_printer : Printer.t
  }

let validate_errors { input_options; run_options = _; output_options } =
  let violations =
    [ input_options.stdin && Option.is_some input_options.zip_file
    , "-zip may not be used with -stdin."
    ; output_options.file_in_place && is_some input_options.zip_file
    , "-in-place may not be used with -zip."
    ; output_options.file_in_place && output_options.stdout
    , "-in-place may not be used with -stdout."
    ; output_options.file_in_place && output_options.diff
    , "-in-place may not be used with -diff."
    ; output_options.file_in_place && (output_options.json_lines || output_options.json_pretty)
    , "-in-place may not be used with -json-lines or -json-pretty."
    ; input_options.anonymous_arguments = None &&
      (input_options.specification_directories = None
       || input_options.specification_directories = Some [])
    , "No templates specified. \
       See -h to specify on the command line, or \
       use -templates \
       <directory-containing-templates>."
    ; Option.is_some input_options.directory_depth
      && Option.value_exn (input_options.directory_depth) < 0
    , "-depth must be 0 or greater."
    ; Sys.is_directory input_options.target_directory = `No
    , "Directory specified with -d or -r or -directory is not a directory."
    ; Option.is_some input_options.specification_directories
      && List.exists
        (Option.value_exn input_options.specification_directories)
        ~f:(fun dir -> not (Sys.is_directory dir = `Yes))
    , "One or more directories specified with -templates is not a directory."
    ; output_options.json_only_diff && (not output_options.json_lines && not output_options.json_pretty)
    , "-json-only-diff can only be supplied with -json-lines or -json-pretty."
    ; let result = Rule.create input_options.rule in
      Or_error.is_error result
    , if Or_error.is_error result then
        Format.sprintf "Match rule parse error: %s@." @@
        Error.to_string_hum (Option.value_exn (Result.error result))
      else
        "UNREACHABLE"
    ]
  in
  List.filter_map violations ~f:(function
      | true, message -> Some (Or_error.error_string message)
      | _ -> None)
  |> Or_error.combine_errors_unit
  |> Result.map_error ~f:(fun error ->
      let message =
        let rec to_string acc =
          function
          | Sexp.Atom s -> s
          | List [] -> ""
          | List (x::[]) -> to_string acc x
          | List (x::xs) ->
            (List.fold xs ~init:acc ~f:to_string) ^ "\nNext error: " ^ to_string acc x
        in
        Error.to_string_hum error
        |> Sexp.of_string
        |> to_string ""
      in
      Error.of_string message)

let emit_warnings { input_options; output_options; _ } =
  let warn_on =
    [ is_some input_options.specification_directories
      && is_some input_options.anonymous_arguments,
      "Templates specified on the command line AND using -templates. Ignoring match
      and rewrite templates on the command line and only using those in directories."
    ; output_options.json_lines = true && output_options.json_pretty = true,
      "Both -json-lines and -json-pretty specified. Using -json-pretty."
    ; output_options.color
      && (output_options.stdout
          || output_options.json_pretty
          || output_options.json_lines
          || output_options.file_in_place)
    , "-color only works with -diff or -match-only."
    ; output_options.count && not input_options.match_only
    , "-count only works with -match-only. Ignoring -count."
    ; input_options.stdin && output_options.file_in_place
    , "-in-place has no effect when -stdin is used. Ignoring -in-place."
    ]
  in
  List.iter warn_on ~f:(function
      | true, message -> Format.eprintf "WARNING: %s@." message
      | _ -> ());
  Ok ()

let create
    ({ input_options =
         { rule
         ; specification_directories
         ; anonymous_arguments
         ; file_filters
         ; zip_file
         ; match_only
         ; stdin
         ; target_directory
         ; directory_depth
         ; exclude_directory_prefix
         }
     ; run_options =
         { sequential
         ; verbose
         ; match_timeout
         ; number_of_workers
         ; dump_statistics
         ; substitute_in_place
         }
     ; output_options =
         ({ file_in_place
          ; color
          ; _
          } as output_options)
     } as configuration)
  : t Or_error.t =
  let open Or_error in
  validate_errors configuration >>= fun () ->
  emit_warnings configuration >>= fun () ->
  let rule = Rule.create rule |> Or_error.ok_exn in
  let specifications =
    match specification_directories, anonymous_arguments with
    | None, Some { match_template; rewrite_template; _ } ->
      if match_only then
        if color then
          (* Fake a replacement with empty to get a nice colored match output. More expensive though. *)
          [ Specification.create ~match_template ~rule ~rewrite_template:"" () ]
        else
          [ Specification.create ~match_template ~rule () ]
      else
        [ Specification.create ~match_template ~rewrite_template ~rule () ]
    | Some specification_directories, _ ->
      parse_template_directories specification_directories
    | _ -> assert false
  in
  let file_filters =
    match anonymous_arguments with
    | None -> file_filters
    | Some { file_filters = None; _ } -> file_filters
    | Some { file_filters = Some anonymous_file_filters; _ } ->
      match file_filters with
      | Some additional_file_filters ->
        Some (additional_file_filters @ anonymous_file_filters)
      | None ->
        Some anonymous_file_filters
  in
  let input_source =
    match stdin, zip_file with
    | true, _ -> Stdin
    | _, Some _ -> Zip
    | false, None -> Directory
  in
  let sources =
    match input_source with
    | Stdin -> `String (In_channel.input_all In_channel.stdin)
    (* TODO(RVT): Unify exclude-dir handling. Currently exclude-dir option must be done while processing zip file in main.ml. *)
    | Zip -> `Zip (Option.value_exn zip_file)
    | Directory -> `Paths (parse_source_directories ?file_filters exclude_directory_prefix target_directory directory_depth)
  in
  let file_in_place = if input_source = Zip || input_source = Stdin then false else file_in_place in
  let output_options = { output_options with file_in_place } in
  let output_printer printable =
    let open Printer in
    match printable with
    | Matches { source_path; matches } ->
      Printer.Match.convert output_options
      |> fun match_output ->
      Printer.Match.print match_output source_path matches
    | Replacements { source_path; replacements; result; source_content } ->
      Printer.Rewrite.convert output_options
      |> fun replacement_output ->
      if match_only && color then
        Printer.Rewrite.print { replacement_output with output_format = Match_only } source_path replacements result source_content
      else
        Printer.Rewrite.print replacement_output source_path replacements result source_content
  in
  return
    { sources
    ; specifications
    ; file_filters
    ; exclude_directory_prefix
    ; run_options =
        { sequential
        ; verbose
        ; match_timeout
        ; number_of_workers
        ; dump_statistics
        ; substitute_in_place
        }
    ; output_printer
    }

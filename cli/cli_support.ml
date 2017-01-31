open Notty

(* Some utilities on top of Notty which I need (might be useful elsewhere?) *)
module Chars = struct
  let hdash a w =
    if !Utils.unicode then
      I.uchar a 0x2500 w 1
    else
      I.char a '-' w 1
  and vdash a h =
    if !Utils.unicode then
      I.uchar a 0x2502 1 h
    else
      I.char a '|' 1 h
  and star a w =
    if !Utils.unicode then
      I.uchar a 0x2605 w 1
    else
      I.char a '*' w 1
end

(* line wrapping is a bit tricky, since we prefer to wrap at word boundaries.
   this is not always possible (if the word length exceeds the line width).

   once we hit such a word, we split at grapheme clusters, the first part of the
   word is put next to the last word, then a list of lines follow, and a last
   partial line.

   while we're there, we also strip whitespaces at the beginning of the line

   example for line width = 5
   input: "foo bar baz"
foo  |
bar  |
baz  |

   input: "foobar bar baz"
fooba|
r bar|
baz  |

   input: "foo foobar baz"
foo f|
oobar|
baz  |

   input: "foobarbazbar boo"
fooba|
rbazb|
ar   |
boo  |

The function graphemes get's the leftover width of the current line, the width
of a standard line and the list of characters of the word, returns the
first line, a list of lines, and the last partial line -- splits the word at
grapheme clusters to wrap it properly.

The function words strips leading whitespaces and delegates to graphemes if
word is too wide.
*)

let graphemes slen linelen chars =
  let seg = Uuseg.create `Grapheme_cluster in
  (* sum up width of chars till len is reached, only split on graphemes.. *)
  let rec go tlen ucs llen line fline lines evt left =
    match Uuseg.add seg evt with
    | `Await ->
      (match left with
       | [] -> go tlen ucs llen line fline lines `End []
       | x::xs -> go tlen ucs llen line fline lines (`Uchar x) xs)
    | `Boundary ->
      let clen = List.fold_left (+) 0 (List.map Uucp.Break.tty_width_hint ucs) in
      if clen + llen < tlen then
        go tlen [] (clen + llen) (ucs @ line) fline lines `Await left
      else if clen + llen = tlen then
        let l = List.rev (ucs @ line) in
        if fline = None then
          go linelen [] 0 [] (Some l) lines `Await left
        else
          go linelen [] 0 [] fline (l::lines) `Await left
      else
        go tlen [] clen ucs fline (List.rev line :: lines) `Await left
    | `Uchar u ->
      go tlen (u::ucs) llen line fline lines `Await left
    | `End -> match fline with
      | Some l -> l, lines, line
      | None -> [], lines, line
  in
  go slen [] 0 [] None [] `Await chars

let words strip a l str =
  let dec = Uutf.decoder ~encoding:`UTF_8 (`String str)
  and seg = Uuseg.create `Word
  in
  let rec go llen word line lines evt =
    match Uuseg.add seg evt with
    | `Await -> (match Uutf.decode dec with
        | `Await | `Malformed _ -> assert false
        | `End | `Uchar _ as evt -> go llen word line lines evt)
    | `Boundary ->
      let wlen w = List.fold_left (+) 0 (List.map Uucp.Break.tty_width_hint w) in
      let wordlen = wlen word in
      let is_ws = match word with
        | [w] -> Uucp.White.is_white_space w
        | _ -> false
      in
      if llen + wordlen <= l then
        (* word fits, all good *)
        if strip && llen = 0 && is_ws then
          (* strip leading ws *)
          go llen [] line lines `Await
        else
          go (llen + wordlen) [] (word @ line) lines `Await
      else if wordlen > l then
        (* need to cut in the middle of a word! *)
        let fl, ls, la = graphemes (l - llen) l (List.rev word) in
        go (wlen la) [] la (ls @ ((List.rev line @ fl) :: lines)) `Await
      else
        (* wrap around, start new line (strip ws) *)
        let word = if strip && is_ws then [] else word in
        go (wlen word) [] word (List.rev line::lines) `Await
    | `Uchar u -> go llen (u::word) line lines `Await
    | `End -> if line = [] then lines else List.rev line::lines
  in
  let lines = go 0 [] [] [] `Await in
  List.map (fun l -> I.uchars a (Array.of_list l)) (List.rev lines)

let split_unicode strip len a str =
  (* first try to fit str in len *)
  let whole = I.string a str in
  if I.width whole <= len then
    [ whole ]
  else
    words strip a len str

let rec split_ascii strip len str acc =
  let open Astring.String in
  if length str <= len then
    List.rev (str :: acc)
  else
    let l, r =
      match find ~rev:true ~start:len ((=) ' ') str with
      | None -> with_range ~len str, with_range ~first:len str
      | Some idx ->
        let first = if strip then succ idx else idx in
        with_range ~len:idx str, with_range ~first str
    in
    split_ascii strip len r (l :: acc)

let render_wrapped_list strip_ws width formatted =
  (* that's a list of a * string! *)
  let lines = List.fold_right (fun (a, m) acc ->
      let lines = Astring.String.cuts ~sep:"\n" ~empty:false m in
      (* now, for each line:
          - if all ASCII -> look for width, maybe split in multiple at spaces
          - if not, gather words (via segmenter) until width reached, start new line *)
      let wrapped = List.fold_right (fun l acc ->
          let els =
            if Astring.String.Ascii.is_valid l then
              let lines = split_ascii strip_ws width l [] in
              List.map (I.string a) lines
            else
              split_unicode strip_ws width a l
          in
          els @ acc)
          lines []
      in
      wrapped @ acc)
      formatted []
  in
  I.vcat lines

let split_on_nl a m =
  List.map (I.string a) (Astring.String.cuts ~sep:"\n" ~empty:false m)

let v_space f width left right =
  let len = width - I.(width left + width right) in
  if len <= 0 then
    I.hpad 0 len I.(left <|> right)
  else
    let fill = I.tile len 1 f in
    I.hcat [ left ; fill ; right ]

let v_center left right width =
  let lw = I.width left
  and rw = I.width right
  in
  match rw, lw >= width with
  | 0, true -> (I.hcrop (lw - width + 1) 0 left, width)
  | 0, false -> (left, succ lw)
  | _, _ ->
    if lw + rw >= width then
      let leftw = min (max (width - rw) (width / 2)) lw in
      let rightw = width - leftw in
      let l = I.hcrop (lw - leftw) 0 left
      and r = I.hcrop 0 (rw - rightw) right
      in
      (I.(l <|> r), succ leftw)
    else
      (I.(left <|> right), succ lw)

let str_to_char_list str : int list =
  let open Uutf in
  List.rev (String.fold_utf_8 (fun acc _ -> function `Uchar i -> i :: acc | `Malformed _ -> acc) [] str)

let char_list_to_str xs =
  let inp = Array.of_list xs in
  let buf = Buffer.create (Array.length inp) in
  Array.iter (Uutf.Buffer.add_utf_8 buf) inp ;
  Buffer.contents buf

let readline_input = function
  | `Key (`Backspace, []) ->
    `Ok (fun (pre, post) ->
        match List.rev pre with
        | [] -> (pre, post)
        | _::tl -> (List.rev tl, post))
  | `Key (`Delete, []) ->
    `Ok (fun (pre, post) ->
        match post with
        | [] -> (pre, post)
        | _::tl -> (pre, tl))
  | `Key (`Home, []) -> `Ok (fun (pre, post) -> [], pre @ post)
  | `Key (`End, []) -> `Ok (fun (pre, post) -> pre @ post, [])
  | `Key (`Arrow `Right, []) ->
    `Ok (fun (pre, post) ->
        match post with
        | [] -> (pre, post)
        | hd::tl -> (pre @ [hd], tl))
  | `Key (`Arrow `Left, []) ->
    `Ok (fun (pre, post) ->
        match List.rev pre with
        | [] -> ([], post)
        | hd::tl -> (List.rev tl, hd :: post))
  | `Key (`Uchar chr, []) -> `Ok (fun (pre, post) -> pre @ [chr], post)
  | k -> `Unhandled k

let emacs_bindings = function
  | `Key (`Uchar 0x41, [`Ctrl]) (* C-a *) -> `Ok (fun (pre, post) -> ([], pre @ post))
  | `Key (`Uchar 0x45, [`Ctrl]) (* C-e *) -> `Ok (fun (pre, post) -> (pre @ post, []))

  | `Key (`Uchar 0x4b, [`Ctrl]) (* C-k *) -> `Ok (fun (pre, _) -> (pre, []))
  | `Key (`Uchar 0x55, [`Ctrl]) (* C-u *) -> `Ok (fun (_, post) -> ([], post))

  | `Key (`Uchar 0x46, [`Ctrl]) (* C-f *) ->
    `Ok (fun (pre, post) ->
        match post with
        | [] -> (pre, post)
        | hd::tl -> (pre @ [hd], tl))
  | `Key (`Uchar 0x42, [`Ctrl]) (* C-b *) ->
    `Ok (fun (pre, post) ->
        match List.rev pre with
        | [] -> ([], post)
        | hd::tl -> (List.rev tl, hd :: post))

  | `Key (`Arrow `Left, [`Ctrl]) ->
    `Ok (fun (pre, post) ->
        let inp, middle = match List.rev pre with
          | ws::xs -> (xs, [ws])
          | [] -> ([], [])
        in
        let _, pre, prep =
          List.fold_left (fun (found, rp, rpp) char ->
              if found then
                (found, char :: rp, rpp)
              else if Uucp.White.is_white_space char then
                (true, char :: rp, rpp)
              else
                (false, rp, char :: rpp) )
            (false, [], [])
            inp
        in
        (pre, prep @ middle @ post))
  | `Key (`Arrow `Right, [`Ctrl]) ->
    `Ok (fun (pre, post) ->
        let inp, middle = match post with
          | ws::xs -> (xs, [ws])
          | [] -> ([], [])
        in
        let _, prep, post =
          List.fold_left (fun (found, rp, rpp) char ->
              if found then
                (found, rp, char :: rpp)
              else if Uucp.White.is_white_space char then
                (true, rp, char :: rpp)
              else
                (false, char :: rp, rpp) )
            (false, [], [])
            inp
        in
        (pre @ middle @ (List.rev prep), List.rev post))

  | k -> `Unhandled k

open EzAPI.TYPES

let (>|=) = Lwt.(>|=)
let return = Lwt.return

module type RAWGEN = sig

  type ('output, 'error, 'security) service0
    constraint 'security = [< EzAPI.security_scheme ]
  type ('arg, 'output, 'error, 'security) service1
    constraint 'security = [< EzAPI.security_scheme ]
  type ('input, 'output, 'error, 'security) post_service0
    constraint 'security = [< EzAPI.security_scheme ]
  type ('arg, 'input, 'output, 'error, 'security) post_service1
    constraint 'security = [< EzAPI.security_scheme ]
  type ('output, 'error) api_result

  val get0 :
    ?post:bool ->
    ?headers:(string * string) list ->
    ?params:(EzAPI.param * EzAPI.arg_value) list ->
    ?msg:string ->                    (* debug msg *)
    EzAPI.base_url ->                 (* API url *)
    ('output, 'error, 'security) service0 ->         (* GET service *)
    ('output, 'error) api_result Lwt.t

  val get1 :
    ?post:bool ->
    ?headers:(string * string) list ->
    ?params:(EzAPI.param * EzAPI.arg_value) list ->
    ?msg: string ->
    EzAPI.base_url ->
    ('arg, 'output, 'error, 'security) service1 ->
    'arg ->
    ('output, 'error) api_result Lwt.t

  val post0 :
    ?headers:(string * string) list ->
    ?params:(EzAPI.param * EzAPI.arg_value) list ->
    ?msg:string ->
    input:'input ->                           (* input *)
    EzAPI.base_url ->                 (* API url *)
    ('input,'output, 'error, 'security) post_service0 -> (* POST service *)
    ('output, 'error) api_result Lwt.t

  val post1 :
    ?headers:(string * string) list ->
    ?params:(EzAPI.param * EzAPI.arg_value) list ->
    ?msg:string ->
    input:'input ->                           (* input *)
    EzAPI.base_url ->                 (* API url *)
    ('arg, 'input,'output, 'error, 'security) post_service1 -> (* POST service *)
    'arg ->
    ('output, 'error) api_result Lwt.t

end

type 'a api_error =
  | KnownError of { code : int ; error : 'a }
  | UnknownError of { code : int ; msg : string option }
type ('output, 'error) api_result = ('output, 'error api_error) result

let string_of_error kn = function
  | KnownError {code; error} ->
    let content = match kn error with None -> "" | Some s -> ": " ^ s in
    Printf.sprintf "Error %d%s" code content
  | UnknownError {code; msg} ->
    let content = match msg with None -> "" | Some s -> ": " ^ s in
    Printf.sprintf "Unknown Error %d%s" code content

module type RAW = RAWGEN
  with type ('output, 'error, 'security) service0 :=
    ('output, 'error, 'security) EzAPI.service0
   and type ('arg, 'output, 'error, 'security) service1 :=
     ('arg, 'output, 'error, 'security) EzAPI.service1
   and type ('input, 'output, 'error, 'security) post_service0 :=
     ('input, 'output, 'error, 'security) EzAPI.post_service0
   and type ('arg, 'input, 'output, 'error, 'security) post_service1 :=
     ('arg, 'input, 'output, 'error, 'security) EzAPI.post_service1
   and type ('output, 'error) api_result := ('output, 'error) api_result

module type LEGACY = RAWGEN
  with type ('output, 'error, 'security) service0 =
    ('output) EzAPI.Legacy.service0
   and type ('arg, 'output, 'error, 'security) service1 =
     ('arg, 'output) EzAPI.Legacy.service1
   and type ('input, 'output, 'error, 'security) post_service0 =
     ('input, 'output) EzAPI.Legacy.post_service0
   and type ('arg, 'input, 'output, 'error, 'security) post_service1 =
     ('arg, 'input, 'output) EzAPI.Legacy.post_service1
   and type ('output, 'error) api_result :=
     ('output, (int * string option)) result

module type S = sig

  include RAW

  module Legacy : LEGACY

  val init : unit -> unit

  val get :
    ?meth:Resto1.method_type ->
    ?headers:(string * string) list ->
    ?msg:string ->
    EzAPI.url ->              (* url *)
    (string, int * string option) result Lwt.t

  val post :
    ?meth:Resto1.method_type ->
    ?content_type:string ->
    ?content:string ->
    ?headers:(string * string) list ->
    ?msg:string ->
    EzAPI.url ->
    (string, int * string option) result Lwt.t

  (* hook executed before every xhr *)
  val add_hook : (unit -> unit) -> unit

end

let log = ref prerr_endline

let request_reply_hook = ref (fun () -> ())

let before_hook = ref (fun () -> ())

let decode_result encoding err_encodings = function
  | Error (code, None) -> Error (UnknownError { code ; msg = None })
  | Error (code, Some msg) ->
    (match err_encodings ~code with
      | None -> Error (UnknownError { code ; msg = Some msg })
      | Some encoding ->
        try Error (
            KnownError { code ; error = EzEncoding.destruct encoding msg })
        with _ -> Error (UnknownError { code ; msg = Some msg })
    )
  | Ok res ->
    let res = match res with "" -> "{}" | res -> res in
    match EzEncoding.destruct encoding res with
    | res -> (Ok res)
    | exception exn ->
      let msg = Printf.sprintf "Decoding error: %s in\n%s"
          (Printexc.to_string exn) res in
      Error (UnknownError { code = -3; msg = Some msg })

let handle_result service res =
  let err_encodings = EzAPI.service_errors service in
  let encoding = EzAPI.service_output service in
  decode_result encoding err_encodings res

let any_get = ref (fun ?meth:_m ?headers:_ ?msg:_ _url ->
    return (Error (-2, Some "No http client loaded"))
  )
let any_post = ref (fun ?meth:_m ?content_type:(_x="") ?content:(_y="") ?headers:_ ?msg:_ _url ->
    return (Error (-2, Some "No http client loaded"))
  )


module Make(S : sig

    val get :
      ?meth:string ->
      ?headers:(string * string) list ->
      ?msg:string -> string ->
      (string, int * string option) result Lwt.t

    val post :
      ?meth:string ->
      ?content_type:string ->
      ?content:string ->
      ?headers:(string * string) list ->
      ?msg:string -> string ->
      (string, int * string option) result Lwt.t

    end) = struct

  let init () =
    any_get := S.get;
    any_post := S.post;
    ()

  let () = init ()

  (* print warnings generated when building the URL before
   sending the request *)
  let internal_get ?meth ?headers ?msg (URL url) =
    EzAPI.warnings (fun s -> Printf.kprintf !log "EzRequest.warning: %s" s);
    let meth = match meth with None -> None | Some m -> Some (
        String.uppercase_ascii @@ EzAPI.str_of_method m) in
    S.get ?meth ?headers ?msg url >|= fun code ->
    !request_reply_hook ();
    code

  let internal_post ?meth ?content_type ?content ?headers ?msg (URL url) =
    EzAPI.warnings (fun s -> Printf.kprintf !log "EzRequest.warning: %s" s);
    let meth = match meth with None -> None | Some m -> Some (
        String.uppercase_ascii @@ EzAPI.str_of_method m) in
    S.post ?meth ?content_type ?content ?headers ?msg url >|= fun code ->
    !request_reply_hook ();
    code

  let add_hook f =
    let old_hook = !before_hook in
    before_hook := (fun () -> old_hook (); f ())


  let get = internal_get
  let post = internal_post

  module Raw = struct

    let get0 ?(post=false) ?headers ?(params=[]) ?msg
        api (service: ('output, 'error, 'security) EzAPI.service0) =
      !before_hook ();
      let meth = EzAPI.service_meth service in
      if post then
        let url = EzAPI.forge0 api service [] in
        let content = EzAPI.encode_args service url params in
        let content_type = EzUrl.content_type in
        internal_post ~meth ~content ~content_type ?headers ?msg url >|=
        handle_result service
      else
        let url = EzAPI.forge0 api service params in
        internal_get ~meth ?headers ?msg url >|= handle_result service

    let get1 ?(post=false) ?headers ?(params=[]) ?msg
        api (service : ('arg,'output, 'error, 'security) EzAPI.service1) (arg : 'arg) =
      !before_hook ();
      let meth = EzAPI.service_meth service in
      if post then
        let url = EzAPI.forge1 api service arg []  in
        let content = EzAPI.encode_args service url params in
        let content_type = EzUrl.content_type in
        internal_post ~meth ~content ~content_type ?headers ?msg url >|=
        handle_result service
      else
        let url = EzAPI.forge1 api service arg params in
        internal_get ~meth ?headers ?msg url >|= handle_result service

    let post0 ?headers ?(params=[]) ?msg ~(input : 'input)
        api (service : ('input,'output, 'error, 'security) EzAPI.post_service0) =
      !before_hook ();
      let meth = EzAPI.service_meth service in
      let input_encoding = EzAPI.service_input service in
      let url = EzAPI.forge0 api service params in
      let content = EzEncoding.construct input_encoding input in
      let content_type = "application/json" in
      internal_post ~meth ~content ~content_type ?headers ?msg url >|=
      handle_result service

    let post1 ?headers ?(params=[]) ?msg ~(input : 'input)
        api (service : ('arg, 'input,'output, 'error, 'security) EzAPI.post_service1) (arg : 'arg) =
      !before_hook ();
      let meth = EzAPI.service_meth service in
      let input_encoding = EzAPI.service_input service in
      let url = EzAPI.forge1 api service arg params in
      let content = EzEncoding.construct input_encoding input in
      let content_type = "application/json" in
      internal_post ~meth ~content ~content_type ?headers ?msg url >|=
      handle_result service
  end

  include Raw


  module Legacy = struct

    type ('output, 'error, 'security) service0 =
      ('output) EzAPI.Legacy.service0
      constraint 'security = [< EzAPI.security_scheme ]

    type ('arg, 'output, 'error, 'security) service1 =
      ('arg, 'output) EzAPI.Legacy.service1
      constraint 'security = [< EzAPI.security_scheme ]

    type ('input, 'output, 'error, 'security) post_service0 =
      ('input, 'output) EzAPI.Legacy.post_service0
      constraint 'security = [< EzAPI.security_scheme ]

    type ('arg, 'input, 'output, 'error, 'security) post_service1 =
      ('arg, 'input, 'output) EzAPI.Legacy.post_service1
      constraint 'security = [< EzAPI.security_scheme ]

    open EzAPI.Legacy

    let unresultize = function
      | Ok res -> Ok res
      | Error UnknownError { code ; msg } -> Error (code, msg)
      | Error KnownError { error ; _ } -> EzAPI.unreachable error


    let get0 ?post ?headers ?params ?msg
        api (service: 'output EzAPI.Legacy.service0) =
      get0 ?post ?headers ?params ?msg api service
      >|= unresultize

    let get1 ?post ?headers ?params ?msg
        api (service : ('arg,'output) service1) (arg : 'arg) =
      get1 ?post ?headers ?params ?msg api service arg
      >|= unresultize

    let post0 ?headers ?params ?msg ~(input : 'input)
        api (service : ('input,'output) post_service0) =
      post0 ?headers ?params ?msg ~input api service
      >|= unresultize

    let post1 ?headers ?params ?msg ~(input : 'input)
        api (service : ('arg, 'input,'output) post_service1) (arg : 'arg) =
      post1 ?headers ?params ?msg ~input api service arg
      >|= unresultize

  end

end

module ANY : S = Make(struct
    let get ?meth ?headers ?msg url = !any_get ?meth ?headers ?msg url
    let post ?meth ?content_type ?content ?headers ?msg url =
      !any_post ?meth ?content_type ?content ?headers ?msg url
  end)

module Default = Make(struct
    let get ?meth:_ ?headers:_ ?msg:_ _url =
      return (Error (-2, Some "No http client loaded"))
    let post ?meth:_ ?content_type:(_x="") ?content:(_y="") ?headers:_ ?msg:_ _url =
      return (Error (-2, Some "No http client loaded"))
  end)

let () = Default.init ()

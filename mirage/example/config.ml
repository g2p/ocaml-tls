open Mirage

let secrets_dir = "sekrit"

let build =
  try
    match Sys.getenv "BUILD" with
    | "client" -> `Client
    | "server" -> `Server
  with Not_found -> `Server

let disk =
  match get_mode () with
  | `Unix -> direct_kv_ro secrets_dir
  | `Xen  -> crunch secrets_dir

let net =
  try match Sys.getenv "NET" with
    | "direct" -> `Direct
    | "socket" -> `Socket
    | _        -> `Direct
  with Not_found -> `Direct

let dhcp =
  try match Sys.getenv "ADDR" with
    | "dhcp"   -> `Dhcp
    | "static" -> `Static
  with Not_found -> `Static

let stack console =
  match net, dhcp with
  | `Direct, `Dhcp   -> direct_stackv4_with_dhcp console tap0
  | `Direct, `Static -> direct_stackv4_with_default_ipv4 console tap0
  | `Socket, _       -> socket_stackv4 console [Ipaddr.V4.any]

let server =
  foreign "Unikernel.Server" @@ console @-> stackv4 @-> kv_ro @-> job

let client =
  foreign "Unikernel.Client" @@ console @-> stackv4 @-> kv_ro @-> job

let () =
  add_to_ocamlfind_libraries ["tls"; "tls.mirage"] ;
  match build with
  | `Server ->
      register "tls-server" [ server $ default_console $ stack default_console $ disk ]
  | `Client ->
      register "tls-client" [ client $ default_console $ stack default_console $ disk ]

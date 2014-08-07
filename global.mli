(** Global values and printing facilities. *)

open Types

(** {2 Global Values} *)

val name                : ident ref (** The name of the module. *)
val file                : string ref (** The name of the file being processed. *)
val version             : string (** Version number. *)

(** {2 Program Options} *)

val run_on_stdin        : bool ref (** Run Dedukti on the standart input.*)
val debug_level         : int ref (** Debug level (0=no messages). *)
val out                 : Format.formatter ref (** Output channel for the TPDB export.*)
val export              : bool ref (** Produce a .dko file. *)
val ignore_redecl       : bool ref (** Do not produce an error when a symbol is redeclared. *)
val color               : bool ref (** Colored output. *)
val autodep             : bool ref

(** {2 Printing Facilities} *)

(** Print in standart output. *)
val print               : ('a, Format.formatter, unit) format -> 'a

(** Print in output set by option -o. *)
val print_out           : ('a, Format.formatter, unit) format -> 'a

(** Print in stderr depending on debug_level. *)
val debug               : int -> loc ->  ('a, Format.formatter, unit) format -> 'a
val debug_no_loc        : int -> ('a, Format.formatter, unit) format -> 'a

(** Print an error message and exit. *)
val fail                : loc -> ('a, Format.formatter, unit, 'b) format4 -> 'a

(** Print a success message. *)
val success             : ('a, Format.formatter, unit) format -> 'a

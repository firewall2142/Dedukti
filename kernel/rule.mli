open Basic
open Term

(** Rewrite rules *)

(** {2 Patterns} *)

(** Basic representation of pattern *)
type pattern =
  | Var      of loc * ident * int * pattern list (** Applied DB variable *)
  | Pattern  of loc * name * pattern list        (** Applied constant    *)
  | Lambda   of loc * ident * pattern            (** Lambda abstraction  *)
  | Brackets of term                             (** Bracket of a term   *)

val get_loc_pat : pattern -> loc

val pattern_to_term : pattern -> term

(** Efficient representation for well-formed linear Miller pattern *)
type wf_pattern =
  | LJoker
  | LVar      of ident * int * int list         (** Applied Miller variable *)
  | LLambda   of ident * wf_pattern             (** Lambda abstraction      *)
  | LPattern  of name * wf_pattern array        (** Applied constant        *)
  | LBoundVar of ident * int * wf_pattern array (** Locally bound variable  *)
  | LACSet    of name * wf_pattern list

(** {2 Linearization} *)

(** [constr] is the type of constraints.
    They are generated by the function check_patterns. *)
type constr = int * term (** DB indicies [i] should be convertible to the term [te] *)

val pp_constr : constr printer

(** {2 Rewrite Rules} *)

type rule_name =
  | Beta
  | Delta of name
  (** Rules associated to the definition of a constant *)
  | Gamma of bool * name
  (** Rules of lambda pi modulo. The first parameter indicates whether
      the name of the rule has been given by the user. *)

val rule_name_eq : rule_name -> rule_name -> bool

val pp_rule_name : rule_name printer

type 'a rule =
  {
    name: rule_name;
    ctx : 'a;
    pat : pattern;
    rhs : term
  }

val get_loc_rule : 'a rule -> loc

type untyped_rule = untyped_context rule

type typed_rule = typed_context rule

(** {2 Errors} *)

type rule_error =
  | BoundVariableExpected          of pattern
  | DistinctBoundVariablesExpected of loc * ident
  | VariableBoundOutsideTheGuard   of term
  | UnboundVariable                of loc * ident * pattern
  | AVariableIsNotAPattern         of loc * ident
  | NonLinearNonEqArguments        of loc * ident

exception RuleError of rule_error

(** {2 Rule infos} *)

type rule_infos =
  { (** location of the rule *)
    l           : loc;
    (** name of the rule *)
    name        : rule_name;
    (** is the rule linear or not ? *)
    linear      : bool;
    (** name of the pattern constant *)
    cst         : name;
    (** arguments list of the pattern constant *)
    args        : pattern list;
    (** right hand side of the rule *)
    rhs         : term;
    (** size of the context of the non-linear version of the rule *)
    ctx_size    : int;
    (** size of the context of the linearized, bracket free version of the rule *)
    esize       : int;
    (** free patterns without constraint *)
    pats        : wf_pattern array;
    (** arities of context variables *)
    arity       : int array;
    (** constraints generated from the pattern to the free pattern *)
    constraints : constr list
  }

val infer_rule_context : rule_infos -> untyped_context
val pattern_of_rule_infos : rule_infos -> pattern

val to_rule_infos : 'a context rule -> rule_infos
(** Converts any rule (typed of untyped) to rule_infos *)

(** {2 Printing} *)

val pp_rule_name       : rule_name       printer
val pp_untyped_rule    : untyped_rule    printer
val pp_typed_rule      : typed_rule      printer
val pp_pattern         : pattern         printer
val pp_wf_pattern      : wf_pattern      printer
val pp_untyped_context : untyped_context printer
val pp_typed_context   : typed_context   printer
val pp_rule_infos      : rule_infos      printer

open Types
open Printf

let rec pp_list sep pp out = function
    | []        -> ()
    | [a]       -> pp out a
    | a::lst    -> fprintf out "%a%s%a" pp a sep (pp_list sep pp) lst

let rec pp_pterm out = function
  | PreType _        -> output_string out "Type"
  | PreId (_,v)      -> pp_ident out v
  | PreQId (_,m,v)   -> fprintf out "%a.%a" pp_ident m pp_ident v
  | PreApp (lst)     -> pp_list " " pp_pterm_wp  out lst
  | PreLam (_,v,a,b) -> fprintf out "%a:%a => %a" pp_ident v pp_pterm_wp a pp_pterm b
  | PrePi (o,a,b)    ->
      ( match o with
          | None       -> fprintf out "%a -> %a" pp_pterm_wp a pp_pterm b
          | Some (_,v) -> fprintf out "%a:%a -> %a" pp_ident v pp_pterm_wp a pp_pterm b )

and pp_pterm_wp out = function
  | PreType _ | PreId _ | PreQId _ as t  -> pp_pterm out t
  | t                                    -> fprintf out "(%a)" pp_pterm t

let pp_pconst out = function
    | ( None , id )     -> pp_ident out id
    | ( Some md , id )  -> fprintf out "%a.%a" pp_ident md pp_ident id

let rec pp_ppattern out = function
  | PPattern (_,md,id,[])       -> pp_pconst out (md,id)
  | PPattern (_,md,id,lst)      ->
      fprintf out "%a %a" pp_pconst (md,id) (pp_list " " pp_ppattern) lst
  | PCondition _                -> assert false
and pp_ppattern_wp out _ = assert false

let pp_const out (m,v) =
  if ident_eq m !Global.name then pp_ident out v
  else fprintf out "%a.%a" pp_ident m pp_ident v

let rec pp_term out = function
  | Kind                -> output_string out "Kind"
  | Type                -> output_string out "Type"
  | Meta n when !Global.debug_level > 0 -> fprintf out "?[%i]" n
  | Meta n              -> output_string out "_"
  | DB  (x,n) when !Global.debug_level > 0 -> fprintf out "%a[%i]" pp_ident x n 
  | DB  (x,n)           -> pp_ident out x
  | Const (m,v)         -> pp_const out (m,v)
  | App args            -> pp_list " " pp_term_wp out args
  | Lam (x,a,f)         -> fprintf out "%a:%a => %a" pp_ident x pp_term_wp a pp_term f
  | Pi  (None,a,b)      -> fprintf out "%a -> %a" pp_term_wp a pp_term b
  | Pi  (Some x,a,b)    -> fprintf out "%a:%a -> %a" pp_ident x pp_term_wp a pp_term b

and pp_term_wp out = function
  | Kind | Type  | DB _ | Const _ as t -> pp_term out t
  | t                                  -> fprintf out "(%a)" pp_term t

let rec pp_pattern out = function
  | Var (id,i)          ->
      if !Global.debug_level > 0 then fprintf out "%a[%i]" pp_ident id i
      else pp_ident out id
  | Condition (i,t)     ->
      if !Global.debug_level > 0 then fprintf out "{ %a }[%i]" pp_term t i
      else fprintf out "{ %a }" pp_term t
  | Pattern (m,v,pats)  ->
      begin
        if Array.length pats = 0 then
          fprintf out "%a.%a" pp_ident m pp_ident v
        else
          fprintf out "%a.%a %a" pp_ident m pp_ident v
            (pp_list " " pp_pattern_wp) (Array.to_list pats)
      end
and pp_pattern_wp out = function
  | Pattern (_,_,_) as p -> fprintf out "(%a)" pp_pattern p
  | p -> pp_pattern out p

let pp_context out ctx =
  pp_list ".\n" (
    fun out (x,ty) ->
      if ident_eq empty x then fprintf out "?: %a" pp_term ty
      else fprintf out "%a: %a" pp_ident x pp_term ty )
    out (List.rev ctx)

let pp_rule out r =
  let pp_decl out (id,ty) = fprintf out "%a:%a" pp_ident id pp_term ty in
    fprintf out "[%a] %a --> %a"
      (pp_list "," pp_decl) r.ctx
      pp_pattern (Pattern (!Global.name,r.id,r.args))
      pp_term r.rhs

let tab t = String.make (t*4) ' '

let rec pp_dtree t out = function
  | Test ([],te,None)   -> pp_term out te
  | Test ([],te,_)      -> assert false
  | Test (lst,te,def)   ->
      let tab = tab t in
      let aux out (i,j) = fprintf out "%a=%a" pp_term i pp_term j in
        fprintf out "\n%sif %a then %a\n%selse %a" tab (pp_list " and " aux) lst
          pp_term te tab (pp_def (t+1)) def
  | Switch (i,cases,def)->
      let tab = tab t in
      let pp_case out (_,m,v,g) =
        fprintf out "\n%sif $%i=%a then %a" tab i
          pp_const (m,v) (pp_dtree (t+1)) g
      in
        fprintf out "%a\n%sdefault: %a" (pp_list "" pp_case)
          cases tab (pp_def (t+1)) def

and pp_def t out = function
  | None        -> output_string out "FAIL"
  | Some g      -> pp_dtree t out g

let pp_rw out (m,v,i,g) =
  fprintf out "GDT for '%a' with %i argument(s): %a"
    pp_const (m,v) i (pp_dtree 0) g

open Basic
open Term
open Dtree
open Ac

let d_matching = Debug.register_flag "Matching"

exception NotUnifiable
exception NotSolvable

type te = term Lazy.t

type status =
  | Unsolved
  | Solved of te
  | Partly of ac_ident * te list

type matching_problem = {
  eq_problems : te eq_problem list array;
  ac_problems : te list ac_problem list;
  status      : status array;
  arities       : int array
}

(*
(**     Printing functions for debugging purposes      **)

let pp_te fmt t = fprintf fmt "%a" pp_term (Lazy.force t)

let pp_indexed_status fmt (i,st) = match st with
  | Unsolved -> ()
  | Solved a -> fprintf fmt "%i = %a" i pp_te a
  | Partly(aci,terms) ->
    fprintf fmt "%i = %a{ %i', %a }" i
      pp_ac_ident aci i
      (pp_list " ; " pp_te) terms

let pp_mp_status sep fmt mp_s =
  let stl = Array.to_list (Array.mapi (fun i st -> (i,st)) mp_s) in
  if List.exists (function (_,Unsolved) -> false | _ -> true) stl
  then fprintf fmt "%swith [ %a ]" sep (pp_list " and " pp_indexed_status) stl

let pp_mp_problems sep pp_eq pp_ac fmt eq_p ac_p =
  fprintf fmt "[ %a | %a ]"
    (pp_arr  sep (pp_eq_problems sep pp_eq)) (Array.mapi (fun i c -> (i,c)) eq_p)
    (pp_list sep (pp_ac_problem      pp_ac)) ac_p

let pp_matching_problem sep fmt mp =
  pp_mp_problems sep pp_te (pp_list " , " pp_te) fmt mp.eq_problems mp.ac_problems;
  pp_mp_status sep fmt mp.status
*)


(* [solve_miller args te] solves following the higher-order unification problem (modulo beta):

    x{_1} => x{_2} => ... x{_[n]} => X x{_i{_1}} .. x{_i{_m}}
    {b =}
    x{_1} => x{_2} => ... x{_[n]} => [te]

    where X is the unknown, x{_i{_1}}, ..., x{_i{_m}} are distinct bound variables.

   If the free variables of [te] that are in x{_1}, ..., x{_[n]} are also in
   x{_i{_1}}, ..., x{_i{_m}} then the problem has a unique solution modulo beta that is
   x{_i{_1}} => .. => x{_i{_m}} => [te].
   Otherwise this problem has no solution and the function raises [NotUnifiable].

   Since we use deBruijn indexes, the problem is given as the equation

   x{_1} => ... => x{_[n]} => X DB(k{_0}) ... DB(k{_m}) =~ x{_1} => ... => x{_[n]} => [te]

   and where [args] = [\[]k{_0}[; ]k{_1}[; ]...[; ]k{_m}[\]].
*)
let solve_miller (var:miller_var) (te:term) : term =
  let depth = var.depth in
  let arity = var.arity in
  let arr = var.mapping in
  let subst l x n k =
    mk_DB l x
      (if n >= k+depth
       (* the var is free  in te:
          - unshift by local [depth]
          - then shift by the [arity] of the meta variable *)
       then (n-depth+arity)
       else
         let n' = arr.(n-k) in
         if n' < 0 then raise NotUnifiable else n' + k
      ) in
  Subst.apply_subst subst 0 te

(* Fast solve for unapplied Miller variables *)
let solve (args:miller_var) (te:term) : term =
  if args.arity = 0
  then try Subst.unshift args.depth te
    with Subst.UnshiftExn -> raise NotUnifiable
  else solve_miller args te


module type Reducer = sig
  val snf  : Signature.t -> term -> term
  val whnf : Signature.t -> term -> term
  val are_convertible : Signature.t -> term -> term -> bool
end

module type Matcher = sig
  val solve_problem :
    Signature.t -> (int -> te) -> (int -> te list) ->
    pre_matching_problem -> te LList.t option
end

module Make (R:Reducer) : Matcher =
struct
  (* Complete solve using a reduction function *)
  let force_solve sg (args:miller_var) t =
    if args.depth = 0 then t
    else
      let te = Lazy.force t in
      Lazy.from_val( try solve args te
                     with NotUnifiable -> solve args (R.snf sg te) )

  (* Try to solve returns None if it fails (from exception monad to Option monad) *)
  let try_force_solve sg args t =
    try Some (force_solve sg args t)
    with NotUnifiable -> None

  let rec add_n_lambdas n t =
    if n == 0 then t else add_n_lambdas (n-1) (mk_Lam dloc dmark None t)

  let lazy_add_n_lambdas n t =
    if n == 0 then t else lazy(add_n_lambdas n (Lazy.force t))

  (** Apply a Miller solution to variables *)
  let apply_args t args =
    mk_App2 t (List.map (fun k -> mk_DB dloc dmark k) args)

    (** [compute_all_sols vars i sols] computes the AC list of all right hand terms
      fixed by substitution  [i] = [sol]  in the left-hand side of
      +{ [i]\[[vars]_1\] ... [i]\[[vars]_n\] } = ...
  *)
  let compute_sols (sol:term) : miller_var list -> term list =
    let rec loop_vars acc = function
      | [] -> acc
      | mvar :: other_var_args ->
        loop_vars ((apply_args sol mvar.vars) :: acc) other_var_args
    in
    loop_vars []

  (** [compute_all_sols vars i sols] computes the AC list of all right hand terms
      fixed by substitution  [i] = +{ [sols] }  in the left-hand side of
      +{ [i]\[[vars]_1\] ... [i]\[[vars]_n\] } = ...
  *)
  let compute_all_sols sols =
    let rec loop_sols acc args = function
      | []           -> acc
      | sol :: osols -> loop_sols ( (apply_args sol args) :: acc) args osols
    in
    let rec loop_term acc = function
      | [] -> acc
      | var :: other_var_args ->
        loop_term (List.rev_append (loop_sols [] var.vars sols) acc) other_var_args
    in
    loop_term []

  (** Remove term [sol] once from list [l]  *)
  let remove_sol sg sol l =
    let rec aux acc = function
      | [] -> None
      | hd :: tl ->
        if R.are_convertible sg (Lazy.force hd) sol
        then Some (List.rev_append acc tl)
        else aux (hd::acc) tl in
    aux [] l

  (** Remove each term in [sols] once from the [terms] list. *)
  let rec remove_sols_occs sg sols terms = match sols with
    | [] -> Some terms
    | sol :: tl ->
      bind_opt (remove_sols_occs sg tl)
        (remove_sol sg sol terms)

  let filter_vars i = List.filter (fun (j,_) -> i != j)
  let var_exists  i = List.exists (fun (j,_) -> i == j)

  let update_status status i s =
    let nstat = Array.copy status in
    nstat.(i) <- s;
    nstat

  let get_occs i =
    let rec aux acc = function
      | [] -> acc
      | (v,args) :: tl -> aux (if v == i then args::acc else acc) tl
    in
    aux []

  let update_ac_problems sg arity i sol :
    te list ac_problem list -> te list ac_problem list option =
    let rec update_ac acc : te list ac_problem list -> te list ac_problem list option
      = function
      | [] -> Some (List.rev acc)
      | p :: tl ->
        let (d,aci,joks,vars,terms) = p in
        (* Fetch occurences of [i] in [vars] *)
        match get_occs i vars with
        | [] -> update_ac (p::acc) tl
        | occs ->
          let sol = R.whnf sg (Lazy.force sol) in
          (* If sol's whnf is still headed by the same AC-symbol then flatten it. *)
          let flat_sols = force_flatten_AC_term (R.snf sg) (fst aci) sol in
          (* If aci represent ACU symbol, remove corresponding neutral element. *)
          let flat_sols =
            match snd aci with
            | ACU neu -> List.filter (fun x -> not (R.are_convertible sg neu x)) flat_sols
            | _ -> flat_sols in
          let lambdaed = List.map (add_n_lambdas arity) flat_sols in
          let shifted = List.map (Subst.shift d) lambdaed in
          let sols = compute_all_sols shifted occs in
          match remove_sols_occs sg sols terms with
          | None -> None
          | Some nterms ->
            let nvars = filter_vars i vars in
            if nvars = []
            then if nterms = [] || joks > 0
              then update_ac acc tl
              else None
            else update_ac ((d,aci,joks,nvars,nterms)::acc) tl
    in
    update_ac []

  (** Resolves variable [i] = [t] *)
  let set_unsolved sg (pb:matching_problem) i sol =
    map_opt
      (* update status of variable [i] *)
      (fun ac_pbs ->
         { pb with ac_problems = ac_pbs; status= update_status pb.status i (Solved sol) })
      (* if the substitution is compatible *)
      (update_ac_problems sg pb.arities.(i) i sol pb.ac_problems)

  let set_partly pb i aci =
    assert(pb.status.(i) == Unsolved);
    { pb with status = update_status pb.status i (Partly(aci,[]))}

  (* A problem of the shape +{X, Y, Z} = +{} has been found.
     Partly solved variable   X = +{a,b,c}
     May no longer be added extra arguments, it is in solved form.
     For each other problem still containing it, remove this variable from the LHS
  *)
  let close_partly sg pb i =
    match pb.status.(i) with
    | Partly(aci,terms) ->
      (* Remove occurence of variable i from all m.v headed AC problems. *)
      let rec update acc = function
        | [] -> Some (List.rev acc)
        | p :: tl ->
          let (d,aci',joks,vars,rhs) = p in
          if ac_ident_eq aci aci' && var_exists i vars
          then
            ( match filter_vars i vars with
              | [] -> if rhs = [] || joks > 0 then update acc tl else None
              | filtered_vars ->
                let a = (d,aci,joks,filtered_vars,rhs) in
                update (a::acc) tl )
          else update (p::acc) tl
      in
      begin
        match update [] pb.ac_problems with
        | None -> None (* If the substitution is incompatible, then fail *)
        | Some ac_pbs ->
          let nprob = { pb with ac_problems = ac_pbs } in
          if terms = [] then (* If [i] is closed on empty list: X = +{} *)
            match aci with
            | _, ACU neu -> (* When + is ACU, it's ok, X = neutral *)
              set_unsolved sg nprob i (Lazy.from_val neu)
            | _ -> None (* Otherwise no solution *)
          else
            let sol = Lazy.from_val (unflatten_AC aci (List.map Lazy.force terms)) in
            set_unsolved sg nprob i sol
      end
    | _ -> assert false

  let add_partly sg pb i sol =
    match pb.status.(i) with
    | Partly(aci,terms) ->
      let rec update_ac acc : te list ac_problem list -> matching_problem option = function
        | [] ->
          let new_status = update_status pb.status i (Partly(aci,sol :: terms)) in
          Some { pb with ac_problems = List.rev acc ; status = new_status }
        | (d,aci',joks,vars,terms as p) :: tl ->
          if ac_ident_eq aci aci' &&  var_exists i vars
          then
            let lambdaed = add_n_lambdas pb.arities.(i) (Lazy.force sol) in
            let shifted = Subst.shift d lambdaed in
            let occs = get_occs i vars in
            let sols = compute_sols shifted occs in
            match remove_sols_occs sg sols terms with
            | None        -> None
            | Some nterms -> update_ac ((d,aci,joks,vars,nterms)::acc) tl
          else update_ac (p::acc) tl
      in
      update_ac [] pb.ac_problems
    | _ -> assert false


(*
let get_all_ac_symbols pb i =
  let set = ref [] in
  let is_in_set e s = List.exists (ac_ident_eq e) s in
  let add e = if not (is_in_set e !set) then set := e :: !set in
  let aux = function
    | _, AC(aci,_,vars,_) -> if List.exists (fun (j,_) -> j == i) vars then add aci
    | _ -> assert false
  in
  List.iter aux pb.problems;
  !set
*)

  (* Fetches most interesting problem and most interesting variable in it.
     Returns None iff the list of remaining problems is empty
     Current implementation always returns the first problem
     and select a variable in it based on the highest following score:
  *)
  let fetch_var pb (_,aci,_,vars,_) =
    (* Look for most interesting variable in the set. *)
    let score (i,_) =
      match pb.status.(i) with
      | Unsolved -> 0
      | Partly(aci',sols) ->
        if ac_ident_eq aci aci' then 1 + List.length sols else max_int-1
      | Solved _ -> assert false
        (* Variables are removed from all problems when they are solved *)
    in
    let aux (bv,bs) v =
      let s = score v in
      if s < bs then (v,s) else (bv,bs) in
    fst (List.fold_left aux ((-1,fo_var),max_int) vars)

  let get_subst arities status =
    let aux i = function
      | Solved sol -> lazy_add_n_lambdas arities.(i) sol
      | _ -> assert false in
    LList.of_array (Array.mapi aux status)

  let solve_ac_problem sg =
    let rec solve_next pb =
      match pb.ac_problems with
      | [] -> Some (get_subst pb.arities pb.status)
      (* If no problem left, compute substitution and return (success !) *)
      | p :: other_problems ->
        (* Else pick an interesting variable... *)
        let (i,args) = fetch_var pb p in
        (* Then explore the problem fetched... *)
        match p with
        | (_,_,joks,[],terms) -> (* If we've chosen an AC equation: +{ X ... } = +{} *)
          (* Left hand side is now empty.
             Either fail (non empty RHS and no joker to match it)
             or simply discard AC equation. *)
          if terms = [] || joks > 0
          then solve_next { pb with ac_problems = other_problems }
          else None
        | (_,aci,_,_,rhs_terms) ->
          (* If we've chosen an AC equation: +{ X, ... } = +{ ... } *)
          match pb.status.(i) with
          | Partly(aci',_) -> (* If X = +{X' ... }*)
            assert (ac_ident_eq aci aci'); (* It can't be the case that X = max{X' ... } *)
            let rec try_add_terms = function
              | [] -> try_solve_next (close_partly sg pb i)
              | t :: tl -> (* Pick a term [t] in RHS set *)
                let sol = try_force_solve sg args t in
                (* Solve  lambda^[d]  X [args]1 ... [args]n = [t] *)
                let npb = bind_opt (add_partly sg pb i) sol in
                (* Add the solution found to the AC-set of partial solution for [i] *)
                match try_solve_next npb with (* Keep solving *)
                | None -> try_add_terms tl
                (* If it failed, backtrack and proceed with the other RHS terms *)
                | a -> a in (* If it succeeds, return the solution *)
            try_add_terms rhs_terms
          | Unsolved -> (* X ins unknown *)
            let rec try_eq_terms = function
              | t :: tl ->  (* Pick a term [t] in the RHS set *)
                let sol = try_force_solve sg args t in
                (* Solve  lambda^[d]  X [args]1 ... [args]n = [t] *)
                let npb = bind_opt (set_unsolved sg pb i) sol in
                (* Hope that we can just set X = solution and have solved for X *)
                (* FIXME: This is probably highly inefficient !
                   We first try X = sol then try again  X = +{sol ...}
                   thus trying to solve twice the same problem *)
                ( match try_solve_next npb with
                  | None -> try_eq_terms tl
                  (* If it failed, backtrack and proceed with the other RHS terms *)
                  | a -> a )  (* If it succeeds, return the solution *)
              | [] -> (* If all terms have been tried unsucessfully, then
                       * the variable [i] is a combination of terms under an AC symbol. *)
                (* NOTE: It seems the commented block should remain commented:
                   At this point, the problem
                     +{X ...} = +{a b ... z}
                   Can only have a solution of the shape X = +{...} otherwise
                   X would be equal to one of the a b ... z  which has already been checked.
                   CAREFUL ! If we remove the check (cf FIXME above) then we need to try
                   all possible AC symbols for X.
                *)
              (*
              let possible_symbols = get_all_ac_symbols pb i in
              let rec try_symbols = function
                | [] -> None
                | aci :: tl ->
              in
              try_symbols possible_symbols
              *)
                solve_next (set_partly pb i aci)
            in
            try_eq_terms rhs_terms
          | Solved _ -> assert false
    and try_solve_next pb = bind_opt solve_next pb in
    solve_next

  (* Rearranges to have easiest AC sets first.
     - Least number of variables first
     - Least number of LHS terms first
     - In case of a tie, problems with at least a joker should be handled second
  *)
  let ac_rearrange problems =
    let ac_f j v t = (List.length v, -List.length t, j > 0) in
    let comp (_,_,j1,v1,t1) (_,_,j2,v2,t2) =
      compare (ac_f j1 v1 t1) (ac_f j2 v2 t2) in
    List.sort comp problems

  let init_ac_problems sg arity status =
    let whnfs = Array.make (Array.length status) None in
    let whnfs i =
      ( match whnfs.(i), status.(i) with
        | Some _ , _ -> ()
        | None, Solved soli -> whnfs.(i) <- Some (R.whnf sg (Lazy.force soli));
        | _ -> () );
      whnfs.(i) in
    let rec update_ac acc = function
      | [] -> List.rev acc
      | (d,aci,joks,vars,terms) :: tl ->
        let rec get_sols acc = function
          | [] -> acc
          | (v,args) :: tl ->
            get_sols
              ( match whnfs v with
                | Some sol ->
                  (* If sol's whnf is still headed by the same AC-symbol then flatten it. *)
                  let flat_sols = force_flatten_AC_term (R.snf sg) (fst aci) sol in
                  (* If aci represent ACU symbol, remove corresponding neutral element. *)
                  let flat_sols =
                    match snd aci with
                    | ACU neu ->
                      List.filter (fun x -> not (R.are_convertible sg neu x)) flat_sols
                    | _ -> flat_sols in
                  let lambdaed = List.map (add_n_lambdas arity.(v)) flat_sols in
                  let shifted = List.map (Subst.shift d) lambdaed in
                  let sols = List.map (fun sol -> apply_args sol args.vars) shifted in
                  sols @ acc
                | _ -> acc) tl
        in
        (* Fetch occurences of [i] in [vars] *)
        match remove_sols_occs sg (get_sols [] vars) terms with
        | None -> raise NotSolvable
        | Some nterms ->
          (* Compute remaining unsolved variables in ac_problem *)
          let nvars = List.filter
              (fun (v,_) -> match status.(v) with Solved _ -> false | _ -> true) vars in
          if nvars = []
          then if nterms = [] || joks > 0
            then update_ac acc tl
            else raise NotSolvable
          else update_ac ((d,aci,joks,nvars,nterms)::acc) tl
    in
    update_ac []

  (* Main solving function.
     Processes equationnal problems as they can be deterministically solved right away
     then hands over to non deterministic AC solver. *)
  let solve_problem sg convert convert_ac pb =
    if pb.pm_ac_problems = []
    then
      let solve_eq = function
        | [] -> assert false
        | [ (args, rhs) ] ->
          lazy_add_n_lambdas args.arity
            (force_solve sg args (convert rhs))
        | (args, rhs) :: opbs ->
          let solu = Lazy.force (force_solve sg args (convert rhs)) in
          List.iter
            (fun (args,rhs) ->
               let subst l x n d =
                 if n - d <= args.depth then mk_DB l x n else raise Not_found in
               let subst_sol = Subst.apply_subst subst 0 (Lazy.force (convert rhs)) in
               if not (R.are_convertible sg solu subst_sol)
               then raise NotSolvable
            )
            opbs;
          Lazy.from_val (add_n_lambdas args.arity solu)
      in
      try Some (LList.map solve_eq pb.pm_eq_problems)
      with NotUnifiable | NotSolvable -> None

    else
      (* First solve equational problems*)
      let solve_eq = function
        | [] -> Unsolved
        | (args, rhs) :: opbs ->
          match try_force_solve sg args (convert rhs) with
          | None -> raise NotSolvable
          | Some solu ->
            List.iter
              (fun (args, rhs) ->
                 let lambdaed = add_n_lambdas args.arity (Lazy.force (convert rhs)) in
                 let shifted = Subst.shift args.depth lambdaed in
                 if not (R.are_convertible sg (Lazy.force solu) (apply_args shifted args.vars))
                 then raise NotSolvable
              )
              opbs;
            Solved solu
      in
      try
        let status = LList.map solve_eq pb.pm_eq_problems in
        let status = Array.of_list (LList.lst status) in
        let ac_problems =
          List.map (fun (d,aci,joks,vars,rhs) -> (d,aci,joks,vars,convert_ac rhs))
            pb.pm_ac_problems in
        (* Update AC problems according to partial solution found *)
        let ac_pbs = init_ac_problems sg pb.pm_arity status ac_problems in
        let pb = { arities = pb.pm_arity;
                   status = status;
                   ac_problems = ac_rearrange ac_pbs;
                   eq_problems=[||] } in
        (* Rearrange AC problems then solve them *)
        solve_ac_problem sg pb
      with NotUnifiable | NotSolvable -> None
end

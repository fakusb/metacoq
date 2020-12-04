open Names
open Tm_util
open Reification

module type BaseDenoter =
sig
  include Reification

  val unquote_ident : quoted_ident -> Id.t
  val unquote_name : quoted_name -> Name.t
  val unquote_aname : quoted_aname -> Name.t Context.binder_annot
  val unquote_relevance : quoted_relevance -> Sorts.relevance
  val unquote_int :  quoted_int -> int
  val unquote_bool : quoted_bool -> bool
  val unquote_int63 :  quoted_int63 -> Uint63.t
  (* val unquote_sort : quoted_sort -> Sorts.t *)
  (* val unquote_sort_family : quoted_sort_family -> Sorts.family *)
  val unquote_cast_kind : quoted_cast_kind -> Constr.cast_kind
  val unquote_kn :  quoted_kernel_name -> KerName.t
  val unquote_inductive :  quoted_inductive -> Names.inductive
  (*val unquote_univ_instance :  quoted_univ_instance -> Univ.Instance.t *)
  val unquote_proj : quoted_proj -> (quoted_inductive * quoted_int * quoted_int)
  val unquote_universe : Evd.evar_map -> quoted_sort -> Evd.evar_map * Univ.Universe.t
  val unquote_universe_instance: Evd.evar_map -> quoted_univ_instance -> Evd.evar_map * Univ.Instance.t
  (* val representsIndConstuctor : quoted_inductive -> Term.constr -> bool *)
  val inspect_term : t -> (t, quoted_int, quoted_ident, quoted_aname, quoted_sort, quoted_cast_kind, quoted_kernel_name, quoted_inductive, quoted_relevance, quoted_univ_instance, quoted_proj, quoted_int63) structure_of_term

end


(* todo: the recursive call is uneeded provided we call it on well formed terms *)

let strict_unquote_universe_mode = ref true


let map_evm (f : 'a -> 'b -> 'a * 'c) (evm : 'a) (l : 'b list) : 'a * ('c list) =
  let evm, res = List.fold_left (fun (evm, l) b -> let evm, c = f evm b in evm, c :: l) (evm, []) l in
  evm, List.rev res

module Denoter (D : BaseDenoter) =
struct

  (* TODO: replace app_full by this abstract version?*)
  let rec app_full_abs (trm: D.t) (acc: D.t list) =
    match D.inspect_term trm with
      ACoq_tApp (f, xs) -> app_full_abs f (xs @ acc)
    | _ -> (trm, acc)

  let denote_term (evm : Evd.evar_map) (trm: D.t) : Evd.evar_map * Constr.t =
    let rec aux evm (trm: D.t) : _ * Constr.t =
      (*    debug (fun () -> Pp.(str "denote_term" ++ spc () ++ pr_constr trm)) ; *)
      match D.inspect_term trm with
      | ACoq_tRel x -> evm, Constr.mkRel (D.unquote_int x + 1)
      | ACoq_tVar x -> evm, Constr.mkVar (D.unquote_ident x)
      | ACoq_tSort x -> let evm, u = D.unquote_universe evm x in evm, Constr.mkType u
      | ACoq_tCast (t,c,ty) -> let evm, t = aux evm t in
        let evm, ty = aux evm ty in
        evm, Constr.mkCast (t, D.unquote_cast_kind c, ty)
      | ACoq_tProd (n,t,b) -> let evm, t = aux evm t in
        let evm, b = aux evm b in
        evm, Constr.mkProd (D.unquote_aname n, t, b)
      | ACoq_tLambda (n,t,b) -> let evm, t = aux evm t in
        let evm, b = aux evm b in
        evm, Constr.mkLambda (D.unquote_aname n, t, b)
      | ACoq_tLetIn (n,e,t,b) -> let evm, e = aux evm e in
        let evm, t = aux evm t in
        let evm, b = aux evm b in
        evm, Constr.mkLetIn (D.unquote_aname n, e, t, b)
      | ACoq_tApp (f,xs) -> let evm, f = aux evm f in
        let evm, xs = map_evm aux evm xs in
        evm, Constr.mkApp (f, Array.of_list xs)
      | ACoq_tConst (s,u) ->
        let s = D.unquote_kn s in
        let evm, u = D.unquote_universe_instance evm u in
        evm, Constr.mkConstU (Constant.make1 s, u)
      | ACoq_tConstruct (i,idx,u) ->
        let ind = D.unquote_inductive i in
        let evm, u = D.unquote_universe_instance evm u in
        evm, Constr.mkConstructU ((ind, D.unquote_int idx + 1), u)
      | ACoq_tInd (i, u) ->
        let i = D.unquote_inductive i in
        let evm, u = D.unquote_universe_instance evm u in
        evm, Constr.mkIndU (i, u)
      | ACoq_tCase (((i, _), r), ty, d, brs) ->
        let ind = D.unquote_inductive i in
        let relevance = D.unquote_relevance r in
        let evm, ty = aux evm ty in
        let evm, d = aux evm d in
        let evm, brs = map_evm aux evm (List.map snd brs) in
        (* todo: reify better case_info *)
        let ci = Inductiveops.make_case_info (Global.env ()) ind relevance Constr.RegularStyle in
        evm, Constr.mkCase (ci, ty, d, Array.of_list brs)
      | ACoq_tFix (lbd, i) ->
        let (names,types,bodies,rargs) = (List.map (fun p->p.adname) lbd,  List.map (fun p->p.adtype) lbd, List.map (fun p->p.adbody) lbd,
                                          List.map (fun p->p.rarg) lbd) in
        let evm, types = map_evm aux evm types in
        let evm, bodies = map_evm aux evm bodies in
        let (names,rargs) = (List.map D.unquote_aname names, List.map D.unquote_int rargs) in
        let la = Array.of_list in
        evm, Constr.mkFix ((la rargs, D.unquote_int i), (la names, la types, la bodies))
      | ACoq_tCoFix (lbd, i) ->
        let (names,types,bodies,rargs) = (List.map (fun p->p.adname) lbd,  List.map (fun p->p.adtype) lbd, List.map (fun p->p.adbody) lbd,
                                          List.map (fun p->p.rarg) lbd) in
        let evm, types = map_evm aux evm types in
        let evm, bodies = map_evm aux evm bodies in
        let (names,rargs) = (List.map D.unquote_aname names, List.map D.unquote_int rargs) in
        let la = Array.of_list in
        evm, Constr.mkCoFix (D.unquote_int i, (la names, la types, la bodies))

      | ACoq_tProj (proj,t) ->
         let (ind, npars, arg) = D.unquote_proj proj in
         let ind' = D.unquote_inductive ind in
         let proj_npars = D.unquote_int npars in
         let proj_arg = D.unquote_int arg in
         let l = (match List.nth (Recordops.lookup_projections ind') proj_arg with
                  | Some p -> Names.Constant.label p
                  | None -> failwith "tproj case of denote_term") in
         let p' = Names.Projection.make (Projection.Repr.make ind' ~proj_npars ~proj_arg l) false in
         let evm, t' = aux evm t in
         evm, Constr.mkProj (p', t')
      (* | _ ->  not_supported_verb trm "big_case"
       *
       * | ACoq_tProj (proj,t) ->
       *   let (ind, _, narg) = D.unquote_proj proj in (\* todo: is narg the correct projection? *\)
       *   let ind' = D.unquote_inductive ind in
       *   let projs = Recordops.lookup_projections ind' in
       *   let evm, t = aux evm t in
       *   (match List.nth projs (D.unquote_int narg) with
       *    | Some p -> evm, Constr.mkProj (Names.Projection.make p false, t)
       *    | None -> (\*bad_term trm *\) ) *)
      | ACoq_tInt x -> evm, Constr.mkInt (D.unquote_int63 x)
      | _ -> failwith "big case of denote_term"

    in aux evm trm

end

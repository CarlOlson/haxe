open Globals
open Type
open Common
open Ast

let curclass = ref null_class

let warned_positions = Hashtbl.create 0

let warn_deprecation com s p_usage =
	if not (Hashtbl.mem warned_positions p_usage) then begin
		Hashtbl.replace warned_positions p_usage s;
		match com.display.dms_kind with
		| DMDiagnostics _ -> ()
		| _ -> com.warning s p_usage;
	end

let print_deprecation_message com meta s p_usage =
	let s = match meta with
		| _,[EConst(String s),_],_ -> s
		| _ -> Printf.sprintf "Usage of this %s is deprecated" s
	in
	warn_deprecation com s p_usage

let check_meta com meta s p_usage =
	try
		print_deprecation_message com (Meta.get Meta.Deprecated meta) s p_usage;
	with Not_found ->
		()

let check_cf com cf p = check_meta com cf.cf_meta "field" p

let check_class com c p = if c != !curclass then check_meta com c.cl_meta "class" p

let check_enum com en p = check_meta com en.e_meta "enum" p

let check_ef com ef p = check_meta com ef.ef_meta "enum field" p

let check_typedef com t p = check_meta com t.t_meta "typedef" p

let check_module_type com mt p = match mt with
	| TClassDecl c -> check_class com c p
	| TEnumDecl en -> check_enum com en p
	| _ -> ()

let run_on_expr com e =
	let rec expr e = match e.eexpr with
		| TField(e1,fa) ->
			expr e1;
			begin match fa with
				| FStatic(c,cf) | FInstance(c,_,cf) ->
					check_class com c e.epos;
					check_cf com cf e.epos
				| FAnon cf ->
					check_cf com cf e.epos
				| FClosure(co,cf) ->
					(match co with None -> () | Some (c,_) -> check_class com c e.epos);
					check_cf com cf e.epos
				| FEnum(en,ef) ->
					check_enum com en e.epos;
					check_ef com ef e.epos;
				| _ ->
					()
			end
		| TNew(c,_,el) ->
			List.iter expr el;
			check_class com c e.epos;
			begin match c.cl_constructor with
				(* The AST doesn't carry the correct overload for TNew, so let's ignore this case... (#8557). *)
				| Some cf when cf.cf_overloads = [] -> check_cf com cf e.epos
				| _ -> ()
			end
		| TTypeExpr(mt) | TCast(_,Some mt) ->
			check_module_type com mt e.epos
		| TMeta((Meta.Deprecated,_,_) as meta,e1) ->
			print_deprecation_message com meta "field" e1.epos;
			expr e1;
		| _ ->
			Type.iter expr e
	in
	expr e

let run_on_field com cf = match cf.cf_expr with None -> () | Some e -> run_on_expr com e

let run com =
	List.iter (fun t -> match t with
		| TClassDecl c ->
			curclass := c;
			(match c.cl_constructor with None -> () | Some cf -> run_on_field com cf);
			(match c.cl_init with None -> () | Some e -> run_on_expr com e);
			List.iter (run_on_field com) c.cl_ordered_statics;
			List.iter (run_on_field com) c.cl_ordered_fields;
		| _ ->
			()
	) com.types
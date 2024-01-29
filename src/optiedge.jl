struct OptiEdge{GT<:AbstractOptiGraph} <: JuMP.AbstractModel
    source_graph::GT
    label::Symbol
    nodes::OrderedSet{OptiNode}
end
function Base.string(edge::OptiEdge)
    return "$(edge.label)"
end
Base.print(io::IO, edge::OptiEdge) = Base.print(io, Base.string(edge))
Base.show(io::IO, edge::OptiEdge) = Base.print(io, edge)

function Base.setindex!(edge::OptiEdge, value::Any, name::Symbol)
    t = (edge, name)
    edge.source_graph.edge_obj_dict[t] = value
    return
end

function Base.getindex(edge::OptiEdge, name::Symbol)
    t = (edge,name)
    return edge.source_graph.edge_obj_dict[t]
end

"""
    graph_backend(edge::OptiEdge)

Return the `GraphMOIBackend` that holds the associated edge model attributes
"""
function graph_backend(edge::OptiEdge)
    return graph_backend(optimizer_graph(edge))
end

"""
    source_graph(edge::OptiEdge)

Return the optigraph that contains the optiedge. This is the optigraph that 
defined said edge and stores edge object dictionary data.
"""
function source_graph(edge::OptiEdge)
    return edge.source_graph
end

"""
    backend_graph(edge::OptiEdge)

Return the `OptiGraph` that contains the edge model attributes. In most cases, this is the 
same as `source_graph(edge)`. For improved performance when modeling with subgraphs, it is 
possible to define all node and edge attributes on the parent-level graph. In this case,
`backend_graph(edge)` would return a parent graph, whereas `source_graph(edge)` would return
the subgraph that contains the node.
"""
function optimizer_graph(edge::OptiEdge)
    return source_graph(edge).optimizer_graph
end

function containing_optigraphs(edge::OptiEdge)
    source = source_graph(edge)
    backend = optimizer_graph(edge)
    graphs = [backend]
    if haskey(source.edge_to_graphs, edge)
        graphs = [graphs; source_graph.edge_to_graphs[edge]]
    end
    return graphs
end

### OptiEdge Extension

function MOI.get(edge::OptiEdge, attr::MOI.AbstractConstraintAttribute, ref::ConstraintRef)
    return MOI.get(graph_backend(edge), attr, ref)
end

function MOI.get(edge::OptiEdge, attr::MOI.ListOfConstraintTypesPresent)
    cons = graph_backend(edge).element_constraints[edge]
    con_types = unique(typeof.(cons))
    type_tuple = [(type.parameters[1],type.parameters[2]) for type in con_types]  
    return type_tuple
end

function MOI.get(
    edge::OptiEdge, 
    attr::MOI.ListOfConstraintIndices{F,S}
) where {F <: MOI.AbstractFunction, S <: MOI.AbstractSet}
    con_inds = MOI.ConstraintIndex{F,S}[]
    for con in graph_backend(edge).element_constraints[edge]
        if (typeof(con).parameters[1] == F && typeof(con).parameters[2] == S)
            push!(con_inds, con)
        end
    end
    return con_inds
end

function JuMP.object_dictionary(edge::OptiEdge)
    return edge.source_graph.edge_obj_dict
end

function JuMP.backend(edge::OptiEdge)
    return JuMP.backend(graph_backend(edge))
end

function JuMP.all_variables(edge::OptiEdge)
    gb = graph_backend(edge)
    con_refs = getindex.(Ref(gb.graph_to_element_map), gb.element_constraints[edge])
    vars = vcat(_extract_variables.(con_refs)...)
    return unique(vars)
end

function JuMP.num_constraints(
    edge::OptiEdge,
    ::Type{F}, 
    ::Type{S}
)::Int64 where {F<:MOI.AbstractFunction,S<:MOI.AbstractSet}
    cons = MOI.get(edge, MOI.ListOfConstraintIndices{F,S}())
    return length(cons)
end

### Edge Constraints

function next_constraint_index(
    edge::OptiEdge, 
    ::Type{F}, 
    ::Type{S}
)::MOI.ConstraintIndex{F,S} where {F<:MOI.AbstractFunction,S<:MOI.AbstractSet}
    index = num_constraints(edge, F, S)
    return MOI.ConstraintIndex{F,S}(index + 1)
end

function JuMP.add_constraint(
    edge::OptiEdge, con::JuMP.AbstractConstraint, name::String=""
)
    con = JuMP.model_convert(edge, con)
    cref = _moi_add_edge_constraint(edge, con)
    return cref
end

function _moi_add_edge_constraint(
    edge::OptiEdge,
    con::JuMP.AbstractConstraint
)
    # get moi function and set
    jump_func = JuMP.jump_function(con)
    moi_func = JuMP.moi_function(con)
    moi_set = JuMP.moi_set(con)

    # create constraint index and reference
    constraint_index = next_constraint_index(
        edge, 
        typeof(moi_func), 
        typeof(moi_set)
    )::MOI.ConstraintIndex{typeof(moi_func),typeof(moi_set)}
    cref = ConstraintRef(edge, constraint_index, JuMP.shape(con))

    # update graph backends
    for graph in containing_optigraphs(edge)
        # add backend variables if linking across optigraphs
        _add_backend_variables(graph_backend(graph), jump_func)

        # update the moi function variable indices
        moi_func_graph = _create_graph_moi_func(graph_backend(graph), moi_func, jump_func)

        # add the constraint to the backend
        _add_element_constraint_to_backend(
            graph_backend(graph), 
            cref, 
            moi_func_graph, 
            moi_set
        )
    end
    return cref
end

### Utilities for querying variables used in constraints

function _extract_variables(ref::ConstraintRef)
    func = JuMP.jump_function(JuMP.constraint_object(ref))
    return _extract_variables(func)
end

function _extract_variables(func::JuMP.GenericAffExpr)
    return collect(keys(func.terms))
end

function _extract_variables(func::JuMP.GenericQuadExpr)
    quad_vars = vcat([[term[2];term[3]] for term in JuMP.quad_terms(func)]...)
    aff_vars = _extract_variables(func.aff)
    return union(quad_vars,aff_vars)
end

function _extract_variables(func::JuMP.GenericNonlinearExpr)
    vars = NodeVariableRef[]
    for i = 1:length(func.args)
        func_arg = func.args[i]
        if func_arg isa JuMP.GenericNonlinearExpr
            append!(vars, _extract_variables(func_arg))
        elseif typeof(func_arg) == NodeVariableRef
            push!(vars, func_arg)
        end
    end
    return vars
end
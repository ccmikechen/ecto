if Code.ensure_loaded?(Postgrex.Connection) do
  defmodule Ecto.Adapters.Postgres.SQL do
    @moduledoc false

    # This module handles the generation of SQL code from queries and for create,
    # update and delete. All queries have to be normalized and validated for
    # correctness before given to this module.

    alias Ecto.Query.QueryExpr
    alias Ecto.Query.JoinExpr
    alias Ecto.Query.Util

    binary_ops =
      [==: "=", !=: "!=", <=: "<=", >=: ">=", <:  "<", >:  ">",
       and: "AND", or: "OR",
       ilike: "ILIKE", like: "LIKE"]

    @binary_ops Dict.keys(binary_ops)

    Enum.map(binary_ops, fn {op, str} ->
      defp handle_fun(unquote(op), 2), do: {:binary_op, unquote(str)}
    end)

    defp handle_fun(fun, _arity), do: {:fun, Atom.to_string(fun)}

    defp quote_table(table), do: "\"#{table}\""
    defp quote_column(column), do: "\"#{column}\""

    # Generate SQL for a select statement
    def select(query) do
      # Generate SQL for every query expression type and combine to one string
      sources = create_names(query)

      from     = from(sources)
      select   = select(query.select, query.distincts, sources)
      join     = join(query, sources)
      where    = where(query.wheres, sources)
      group_by = group_by(query.group_bys, sources)
      having   = having(query.havings, sources)
      order_by = order_by(query.order_bys, sources)
      limit    = limit(query.limit, sources)
      offset   = offset(query.offset, sources)
      lock     = lock(query.lock)

      sql =
        [select, from, join, where, group_by, having, order_by, limit, offset, lock]
        |> Enum.filter(&(&1 != nil))
        |> List.flatten
        |> Enum.join(" ")

      sql
    end

    # Generate SQL for an insert statement
    def insert(model, returning) do
      module = model.__struct__
      table  = module.__schema__(:source)

      {fields, values} = module.__schema__(:keywords, model)
        |> Enum.filter(fn {_, val} -> val != nil end)
        |> :lists.unzip

      sql = "INSERT INTO #{quote_table(table)}"

      if fields == [] do
        sql = sql <> " DEFAULT VALUES"
      else
        sql = sql <>
          " (" <> Enum.map_join(fields, ", ", &quote_column(&1)) <> ") " <>
          "VALUES (" <> Enum.map_join(1..length(values), ", ", &"$#{&1}") <> ")"
      end

      if !Enum.empty?(returning) do
        sql = sql <> " RETURNING " <> Enum.map_join(returning, ", ", &quote_column(&1))
      end

      {sql, values}
    end

    # Generate SQL for an update statement
    def update(model) do
      module   = model.__struct__
      table    = module.__schema__(:source)
      pk_field = module.__schema__(:primary_key)
      pk_value = Map.get(model, pk_field)

      {fields, values} = module.__schema__(:keywords, model, primary_key: false)
                         |> :lists.unzip

      fields = Enum.with_index(fields)
      sql_sets = Enum.map_join(fields, ", ", fn {k, ix} ->
        "#{quote_column(k)} = $#{ix+1}"
      end)

      sql =
        "UPDATE #{quote_table(table)} SET " <> sql_sets <> " " <>
        "WHERE #{quote_column(pk_field)} = $#{length(values)+1}"

      {sql, values ++ [pk_value]}
    end

    # Generate SQL for an update all statement
    def update_all(query, values) do
      sources       = create_names(query)
      from          = elem(sources, 0)
      {table, name} = Util.source(from)

      zipped_sql = Enum.map_join(values, ", ", fn {field, expr} ->
        "#{quote_column(field)} = #{expr(expr, sources)}"
      end)

      where = where(query.wheres, sources)
      where = if where, do: " " <> where, else: ""

      "UPDATE #{quote_table(table)} AS #{name} " <>
      "SET " <> zipped_sql <>
      where
    end

    # Generate SQL for a delete statement
    def delete(model) do
      module   = model.__struct__
      table    = module.__schema__(:source)
      pk_field = module.__schema__(:primary_key)
      pk_value = Map.get(model, pk_field)

      sql = "DELETE FROM #{quote_table(table)} WHERE #{quote_column(pk_field)} = $1"
      {sql, [pk_value]}
    end

    # Generate SQL for an delete all statement
    def delete_all(query) do
      sources         = create_names(query)
      from            = elem(sources, 0)
      {table, name}   = Util.source(from)

      where = where(query.wheres, sources)
      where = if where, do: " " <> where, else: ""
      "DELETE FROM #{quote_table(table)} AS #{name}" <> where
    end

    defp select(%QueryExpr{expr: expr}, [], sources) do
      "SELECT " <> select_clause(expr, sources)
    end

    defp select(%QueryExpr{expr: expr}, distincts, sources) do
      exprs =
        Enum.map_join(distincts, ", ", fn
          %QueryExpr{expr: expr} ->
            Enum.map_join(expr, ", ", &expr(&1, sources))
        end)

      exprs = Enum.join(exprs, ", ")
      "SELECT DISTINCT ON (" <> exprs <> ") " <> select_clause(expr, sources)
    end

    defp from(sources) do
      {table, name} = elem(sources, 0) |> Util.source
      "FROM #{quote_table(table)} AS #{name}"
    end

    defp join(query, sources) do
      joins = Stream.with_index(query.joins)
      Enum.map(joins, fn
        {%JoinExpr{on: %QueryExpr{expr: expr}, qual: qual}, ix} ->
          source        = elem(sources, ix+1)
          {table, name} = Util.source(source)

          on   = expr(expr, sources)
          qual = join_qual(qual)

          "#{qual} JOIN #{quote_table(table)} AS #{name} ON " <> on
      end)
    end

    defp join_qual(:inner), do: "INNER"
    defp join_qual(:left),  do: "LEFT OUTER"
    defp join_qual(:right), do: "RIGHT OUTER"
    defp join_qual(:full),  do: "FULL OUTER"

    defp where(wheres, sources) do
      boolean("WHERE", wheres, sources)
    end

    defp having(havings, sources) do
      boolean("HAVING", havings, sources)
    end

    defp group_by([], _sources), do: nil

    defp group_by(group_bys, sources) do
      exprs =
        Enum.map(group_bys, fn
          %QueryExpr{expr: expr} ->
            Enum.map_join(expr, ", ", &expr(&1, sources))
        end)

      exprs = Enum.join(exprs, ", ")
      "GROUP BY " <> exprs
    end

    defp order_by([], _sources), do: nil

    defp order_by(order_bys, sources) do
      exprs =
        Enum.map(order_bys, fn
          %QueryExpr{expr: expr} ->
            Enum.map_join(expr, ", ", &order_by_expr(&1, sources))
        end)

      exprs = Enum.join(exprs, ", ")
      "ORDER BY " <> exprs
    end

    defp order_by_expr({dir, expr}, sources) do
      str = expr(expr, sources)
      case dir do
        :asc  -> str
        :desc -> str <> " DESC"
      end
    end

    defp limit(nil, _sources), do: nil
    defp limit(%Ecto.Query.QueryExpr{expr: expr}, sources) do
      "LIMIT " <> expr(expr, sources)
    end

    defp offset(nil, _sources), do: nil
    defp offset(%Ecto.Query.QueryExpr{expr: expr}, sources) do
      "OFFSET " <> expr(expr, sources)
    end

    defp lock(nil), do: nil
    defp lock(false), do: nil
    defp lock(true), do: "FOR UPDATE"
    defp lock(lock_clause), do: lock_clause

    defp boolean(_name, [], _sources), do: nil

    defp boolean(name, query_exprs, sources) do
      exprs =
        Enum.map(query_exprs, fn
          %QueryExpr{expr: expr} ->
            "(" <> expr(expr, sources) <> ")"
        end)

      exprs = Enum.join(exprs, " AND ")
      name <> " " <> exprs
    end

    defp expr({arg, _, []}, sources) when is_tuple(arg) do
      expr(arg, sources)
    end

    defp expr(%Ecto.Query.Fragment{parts: parts}, sources) do
      Enum.map_join(parts, "", fn
        part when is_binary(part) -> part
        expr -> expr(expr, sources)
      end)
    end

    defp expr({:^, [], [ix]}, _sources) do
      "$#{ix+1}"
    end

    defp expr({:., _, [{:&, _, [_]} = var, field]}, sources) when is_atom(field) do
      {_, name} = Util.find_source(sources, var) |> Util.source
      "#{name}.#{quote_column(field)}"
    end

    defp expr({:&, _, [_]} = var, sources) do
      source    = Util.find_source(sources, var)
      model     = Util.model(source)
      fields    = model.__schema__(:field_names)
      {_, name} = Util.source(source)

      Enum.map_join(fields, ", ", &"#{name}.#{quote_column(&1)}")
    end

    defp expr({:in, _, [left, right]}, sources) do
      expr(left, sources) <> " = ANY (" <> expr(right, sources) <> ")"
    end

    defp expr({:is_nil, _, [arg]}, sources) do
      "#{expr(arg, sources)} IS NULL"
    end

    defp expr({:not, _, [expr]}, sources) do
      "NOT (" <> expr(expr, sources) <> ")"
    end

    defp expr({fun, _, args}, sources) when is_atom(fun) and is_list(args) do
      case handle_fun(fun, length(args)) do
        {:binary_op, op} ->
          [left, right] = args
          op_to_binary(left, sources) <>
          " #{op} "
          <> op_to_binary(right, sources)

        {:fun, fun} ->
          "#{fun}(" <> Enum.map_join(args, ", ", &expr(&1, sources)) <> ")"
      end
    end

    defp expr(list, sources) when is_list(list) do
      "ARRAY[" <> Enum.map_join(list, ", ", &expr(&1, sources)) <> "]"
    end

    defp expr(%Ecto.Query.Tagged{value: binary, type: :binary}, _sources) when is_binary(binary) do
      hex = Base.encode16(binary, case: :lower)
      "'\\x#{hex}'"
    end

    defp expr(%Ecto.Query.Tagged{value: binary, type: :uuid}, _sources) when is_binary(binary) do
      hex = Base.encode16(binary)
      "'#{hex}'"
    end

    defp expr(nil, _sources),   do: "NULL"
    defp expr(true, _sources),  do: "TRUE"
    defp expr(false, _sources), do: "FALSE"

    defp expr(literal, _sources) when is_binary(literal) do
      "'#{escape_string(literal)}'"
    end

    defp expr(literal, _sources) when is_integer(literal) do
      String.Chars.Integer.to_string(literal)
    end

    defp expr(literal, _sources) when is_float(literal) do
      String.Chars.Float.to_string(literal) <> "::float"
    end

    defp op_to_binary({op, _, [_, _]} = expr, sources) when op in @binary_ops do
      "(" <> expr(expr, sources) <> ")"
    end

    defp op_to_binary(expr, sources) do
      expr(expr, sources)
    end

    defp select_clause(expr, sources) do
      flatten_select(expr) |> Enum.map_join(", ", &expr(&1, sources))
    end

    defp flatten_select({left, right}) do
      flatten_select({:{}, [], [left, right]})
    end

    defp flatten_select({:{}, _, elems}) do
      Enum.flat_map(elems, &flatten_select/1)
    end

    defp flatten_select(list) when is_list(list) do
      Enum.flat_map(list, &flatten_select/1)
    end

    defp flatten_select(expr) do
      [expr]
    end

    defp escape_string(value) when is_binary(value) do
      :binary.replace(value, "'", "''", [:global])
    end

    defp create_names(query) do
      sources = query.sources |> Tuple.to_list
      Enum.reduce(sources, [], fn {table, model}, names ->
        name = unique_name(names, String.first(table), 0)
        [{{table, name}, model}|names]
      end) |> Enum.reverse |> List.to_tuple
    end

    # Brute force find unique name
    defp unique_name(names, name, counter) do
      counted_name = name <> Integer.to_string(counter)
      if Enum.any?(names, fn {{_, n}, _} -> n == counted_name end) do
        unique_name(names, name, counter+1)
      else
        counted_name
      end
    end
  end
end

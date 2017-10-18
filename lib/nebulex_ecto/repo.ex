defmodule Nebulex.Ecto.Repo do
  @moduledoc """
  Wrapper/Facade on top of `Nebulex.Cache` and `Ecto.Repo`.

  This module encapsulates the access to the Ecto repo and Nebulex cache,
  providing a set of functions compliant with the `Ecto.Repo` API.

  For retrieve-like functions, the wrapper access the cache first, if the
  requested data is found, then it is returned right away, otherwise, the
  wrapper tries to retrieve the data from the repo (database), and if the
  data is found, then it is cached so the next time it can be retrieved
  directly from cache.

  For write functions (insert, update, delete, ...), the wrapper runs the
  eviction logic, which can be delete the data from cache or just replace it;
  depending on the `:nbx_evict` option.

  When used, `Nebulex.Ecto.Repo` expects the `:otp_app` as option.
  The `:otp_app` should point to an OTP application that has
  the wrapper configuration. For example:

      defmodule MyApp.CacheableRepo do
        use Nebulex.Ecto.Repo, otp_app: :my_app
      end

  Could be configured with:

      config :my_app, MyApp.CacheableRepo,
        cache: MyApp.Cache,
        repo: MyApp.Repo

  The cache and repo:

      defmodule MyApp.Cache do
        use Nebulex.Cache, otp_app: :my_app
      end

      defmodule MyApp.Repo do
        use Ecto.Repo, otp_app: :my_app
      end

  And this is an example of how their configuration would looks like:

      config :my_app, MyApp.Cache,
        adapter: Nebulex.Adapters.Local

      config :my_app, MyApp.Repo,
        adapter: Ecto.Adapters.Postgres,
        database: "ecto_simple",
        username: "postgres",
        password: "postgres",
        hostname: "localhost"

  ## Compile-time configuration options

    * `:cache` - a compile-time option that specifies the Nebulex cache
      to be used by the wrapper.

    * `:repo` - a compile-time option that specifies the Ecto repo
      to be used by the wrapper.

  To configure `cache` and `repo`, see the `Nebulex` and `Ecto` documentation
  respectively.

  ## Shared options

  Almost all of the operations below accept the following options:

    * `:nbx_key` - specifies the key to be used for cache access.
      By default is set to `{Ecto.Schema.t, id :: term}`, assuming
      the schema has a field `id` which is the primary key; if this
      is not your case, you must provide the `:nbx_key`.

    * `:nbx_evict` - specifies the eviction strategy, if it is set to
      `:delete` (the default), then the key is removed from cache, and
      if it is set to `:replace`, then the key is replaced with the
      new value into the cache.
  """

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      otp_app = Keyword.fetch!(opts, :otp_app)

      {otp_app, cache, repo} = Nebulex.Ecto.Repo.compile_config(__MODULE__, opts)
      @cache cache
      @repo repo

      def get(queryable, id, opts \\ []) do
        do_get(queryable, id, opts, &@repo.get/3)
      end

      def get!(queryable, id, opts \\ []) do
        do_get(queryable, id, opts, &@repo.get!/3)
      end

      def get_by(queryable, clauses, opts \\ []) do
        do_get(queryable, clauses, opts, &@repo.get_by/3)
      end

      def get_by!(queryable, clauses, opts \\ []) do
        do_get(queryable, clauses, opts, &@repo.get_by!/3)
      end

      def insert(struct_or_changeset, opts \\ []) do
        execute(&@repo.insert/2, struct_or_changeset, opts)
      end

      def insert!(struct_or_changeset, opts \\ []) do
        execute!(&@repo.insert!/2, struct_or_changeset, opts)
      end

      def update(changeset, opts \\ []) do
        execute(&@repo.update/2, changeset, opts)
      end

      def update!(changeset, opts \\ []) do
        execute!(&@repo.update!/2, changeset, opts)
      end

      def delete(struct_or_changeset, opts \\ []) do
        execute(&@repo.delete/2, struct_or_changeset, Keyword.put(opts, :nbx_evict, :delete))
      end

      def delete!(struct_or_changeset, opts \\ []) do
        execute!(&@repo.delete!/2, struct_or_changeset, Keyword.put(opts, :nbx_evict, :delete))
      end

      def insert_or_update(struct_or_changeset, opts \\ []) do
        execute(&@repo.insert_or_update/2, struct_or_changeset, opts)
      end

      def insert_or_update!(struct_or_changeset, opts \\ []) do
        execute!(&@repo.insert_or_update!/2, struct_or_changeset, opts)
      end

      ## Helpers

      defp do_get(queryable, key, opts, repo_fallback) do
        {nbx_key, opts} = Keyword.pop(opts, :nbx_key)
        cache_key = nbx_key || key!(queryable, key)

        cond do
          value = @cache.get(cache_key) ->
            value
          value = repo_fallback.(queryable, key, opts) ->
            @cache.set(cache_key, value)
          true ->
            nil
        end
      end

      defp execute(fun, struct_or_changeset, opts) do
        {nbx_key, opts} = Keyword.pop(opts, :nbx_key)
        {nbx_evict, opts} = Keyword.pop(opts, :nbx_evict, :delete)

        case fun.(struct_or_changeset, opts) do
          {:ok, schema} = res ->
            cache_key = nbx_key || key!(schema, schema.id)
            _ = cache_evict(nbx_evict, cache_key, schema)
            res
          error ->
            error
        end
      end

      defp execute!(fun, struct_or_changeset, opts) do
        {nbx_key, opts} = Keyword.pop(opts, :nbx_key)
        {nbx_evict, opts} = Keyword.pop(opts, :nbx_evict, :delete)

        schema = fun.(struct_or_changeset, opts)
        cache_key = nbx_key || key!(schema, schema.id)
        _ = cache_evict(nbx_evict, cache_key, schema)
        schema
      end

      defp cache_evict(:delete, key, _),
        do: @cache.delete(key)
      defp cache_evict(:replace, key, value),
        do: @cache.set(key, value)

      defp key!(%Ecto.Query{from: {_tablename, schema}}, key),
        do: {schema, key}
      defp key!(%{__struct__: struct}, key),
        do: {struct, key}
      defp key!(struct, key) when is_atom(struct),
        do: {struct, key}
    end
  end

  @doc """
  Retrieves the compile time configuration.
  """
  def compile_config(facade, opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    config  = Application.get_env(otp_app, facade, [])

    unless cache = opts[:cache] || config[:cache] do
      raise ArgumentError,
        "missing :cache configuration in config #{inspect otp_app}, #{inspect facade}"
    end

    unless repo = opts[:repo] || config[:repo] do
      raise ArgumentError,
        "missing :repo configuration in config #{inspect otp_app}, #{inspect facade}"
    end

    {otp_app, cache, repo}
  end
end

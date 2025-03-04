defmodule Beacon.Content do
  @moduledoc """
  The building blocks for composing web pages: Layouts, Pages, Components, Stylesheets, and Snippets.

  ## Templates

  Layout and Pages work together as pages require a layout to display its content,
  the minimal template for a layout that can exist is the following:

  ```heex
  <%= @inner_content %>
  ```

  And pages templates can be written in [HEEx](https://hexdocs.pm/phoenix_live_view/assigns-eex.html)
  or [Markdown](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax) formats.

  ## Meta Tags

  Meta Tags can are defined in 3 levels:

    * Site - fixed meta tags displayed on all pages, see `default_site_meta_tags/0`
    * Layouts - applies to all pages used by the template.
    * Page - only applies to the specific page.

  """
  import Ecto.Query

  alias Beacon.Content.Component
  alias Beacon.Content.Layout
  alias Beacon.Content.LayoutEvent
  alias Beacon.Content.LayoutSnapshot
  alias Beacon.Content.Page
  alias Beacon.Content.PageEvent
  alias Beacon.Content.PageEventHandler
  alias Beacon.Content.PageField
  alias Beacon.Content.PageSnapshot
  alias Beacon.Content.PageVariant
  alias Beacon.Content.Snippets
  alias Beacon.Content.Stylesheet
  alias Beacon.Lifecycle
  alias Beacon.PubSub
  alias Beacon.Repo
  alias Beacon.Template.HEEx.HEExDecoder
  alias Beacon.Types.Site
  alias Ecto.Changeset

  @doc """
  Returns the list of meta tags that are applied to all pages by default.

  These meta tags can be overwriten or extended on a Layout or Page level.
  """
  @spec default_site_meta_tags() :: [map()]
  def default_site_meta_tags do
    [
      %{"charset" => "utf-8"},
      %{"http-equiv" => "X-UA-Compatible", "content" => "IE=edge"},
      %{"name" => "viewport", "content" => "width=device-width, initial-scale=1"}
    ]
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking layout changes.

  ## Example

      iex> change_layout(layout, %{title: "New Home"})
      %Ecto.Changeset{data: %Layout{}}

  """
  @doc type: :layouts
  @spec change_layout(Layout.t(), map()) :: Changeset.t()
  def change_layout(%Layout{} = layout, attrs \\ %{}) do
    Layout.changeset(layout, attrs)
  end

  @doc """
  Creates a layout.

  ## Example

      iex> create_layout(%{title: "Home"})
      {:ok, %Layout{}}

  """
  @doc type: :layouts
  @spec create_layout(map()) :: {:ok, Layout.t()} | {:error, Changeset.t()}
  def create_layout(attrs) do
    changeset = Layout.changeset(%Layout{}, attrs)

    Repo.transact(fn ->
      with {:ok, changeset} <- validate_layout_template(changeset),
           {:ok, layout} <- Repo.insert(changeset),
           {:ok, _event} <- create_layout_event(layout, "created") do
        {:ok, layout}
      end
    end)
  end

  @doc """
  Creates a layout.
  """
  @doc type: :layouts
  @spec create_layout!(map()) :: Layout.t()
  def create_layout!(attrs) do
    case create_layout(attrs) do
      {:ok, layout} -> layout
      {:error, changeset} -> raise "failed to create layout, got: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  Updates a layout.

  ## Example

      iex> update_layout(layout, %{title: "New Home"})
      {:ok, %Layout{}}

  """
  @doc type: :layouts
  @spec update_layout(Layout.t(), map()) :: {:ok, Layout.t()} | {:error, Changeset.t()}
  def update_layout(%Layout{} = layout, attrs) do
    changeset = Layout.changeset(layout, attrs)

    with {:ok, changeset} <- validate_layout_template(changeset) do
      Repo.update(changeset)
    end
  end

  @doc """
  Publishes `layout` and reload resources to render the updated layout and pages.

  Event + snapshot
  """
  @doc type: :layouts
  @spec publish_layout(Layout.t()) :: {:ok, Layout.t()} | {:error, Changeset.t() | term()}
  def publish_layout(%Layout{} = layout) do
    publish = fn layout ->
      changeset = Layout.changeset(layout, %{})

      Repo.transact(fn ->
        with {:ok, _changeset} <- validate_layout_template(changeset),
             {:ok, event} <- create_layout_event(layout, "published"),
             {:ok, _snapshot} <- create_layout_snapshot(layout, event) do
          {:ok, layout}
        end
      end)
    end

    with {:ok, layout} <- publish.(layout),
         :ok <- PubSub.layout_published(layout) do
      {:ok, layout}
    end
  end

  @doc type: :layouts
  @spec publish_layout(Ecto.UUID.t()) :: {:ok, Layout.t()} | any()
  def publish_layout(id) when is_binary(id) do
    id
    |> get_layout()
    |> publish_layout()
  end

  defp validate_layout_template(changeset) do
    site = Changeset.get_field(changeset, :site)
    template = Changeset.get_field(changeset, :template)
    metadata = %Beacon.Template.LoadMetadata{site: site, path: "nopath"}

    case do_validate_template(changeset, :template, :heex, template, metadata) do
      %Changeset{errors: []} = changeset -> {:ok, changeset}
      %Changeset{} = changeset -> {:error, changeset}
    end
  end

  @doc false
  def create_layout_event(layout, event) do
    attrs = %{"site" => layout.site, "layout_id" => layout.id, "event" => event}

    %LayoutEvent{}
    |> Changeset.cast(attrs, [:site, :layout_id, :event])
    |> Changeset.validate_required([:site, :layout_id, :event])
    |> Repo.insert()
  end

  @doc false
  def create_layout_snapshot(layout, event) do
    attrs = %{"site" => layout.site, "schema_version" => Layout.version(), "layout_id" => layout.id, "layout" => layout, "event_id" => event.id}

    %LayoutSnapshot{}
    |> Changeset.cast(attrs, [:site, :schema_version, :layout_id, :layout, :event_id])
    |> Changeset.validate_required([:site, :schema_version, :layout_id, :layout, :event_id])
    |> Repo.insert()
  end

  @doc """
  Gets a single layout by `id`.

  ## Example

      iex> get_layout("fd70e5fe-9bd8-41ed-94eb-5459c9bb05fc")
      %Layout{}

  """
  @doc type: :layouts
  @spec get_layout(Ecto.UUID.t()) :: Layout.t() | nil
  def get_layout(id) do
    Repo.get(Layout, id)
  end

  @doc type: :layouts
  def get_layout!(id) when is_binary(id) do
    Repo.get!(Layout, id)
  end

  @doc """
  Gets a single layout by `clauses`.

  ## Example

      iex> get_layout_by(site, title: "blog")
      %Layout{}

  """
  @doc type: :layouts
  @spec get_layout_by(Site.t(), keyword(), keyword()) :: Layout.t() | nil
  def get_layout_by(site, clauses, opts \\ []) when is_atom(site) and is_list(clauses) do
    clauses = Keyword.put(clauses, :site, site)
    Repo.get_by(Layout, clauses, opts)
  end

  @doc """
  Returns all layout events with associated snapshot if available.

  ## Example

      iex> list_layout_events(:my_site, layout_id)
      [
        %LayoutEvent{event: :created, snapshot: nil},
        %LayoutEvent{event: :published, snapshot: %LayoutSnapshot{}}
      ]

  """
  @doc type: :layouts
  @spec list_layout_events(Site.t(), Ecto.UUID.t()) :: [LayoutEvent.t()]
  def list_layout_events(site, layout_id) when is_atom(site) and is_binary(layout_id) do
    Repo.all(
      from event in LayoutEvent,
        left_join: snapshot in LayoutSnapshot,
        on: snapshot.event_id == event.id,
        where: event.site == ^site and event.layout_id == ^layout_id,
        preload: [snapshot: snapshot],
        order_by: [desc: event.inserted_at]
    )
  end

  @doc """
  Returns the latest layout event.

  Useful to find the status of a layout.

  ## Example

      iex> get_latest_layout_event(:my_site, layout_id)
      %LayoutEvent{event: :published}

  """
  @doc type: :layouts
  @spec get_latest_layout_event(Site.t(), Ecto.UUID.t()) :: LayoutEvent.t() | nil
  def get_latest_layout_event(site, layout_id) when is_atom(site) and is_binary(layout_id) do
    Repo.one(
      from event in LayoutEvent,
        where: event.site == ^site and event.layout_id == ^layout_id,
        limit: 1,
        order_by: [desc: event.inserted_at]
    )
  end

  @doc """
  List layouts.

  ## Options

    * `:per_page` - limit how many records are returned, or pass `:infinity` to return all records.
    * `:query` - search layouts by title.

  """
  @doc type: :layouts
  @spec list_layouts(Site.t(), keyword()) :: [Layout.t()]
  def list_layouts(site, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    search = Keyword.get(opts, :query)

    site
    |> query_list_layouts_base()
    |> query_list_layouts_limit(per_page)
    |> query_list_layouts_search(search)
    |> Repo.all()
  end

  defp query_list_layouts_base(site) do
    from l in Layout,
      where: l.site == ^site,
      order_by: [asc: l.title]
  end

  defp query_list_layouts_limit(query, limit) when is_integer(limit), do: from(q in query, limit: ^limit)
  defp query_list_layouts_limit(query, :infinity = _limit), do: query
  defp query_list_layouts_limit(query, _per_page), do: from(q in query, limit: 20)
  defp query_list_layouts_search(query, search) when is_binary(search), do: from(q in query, where: ilike(q.title, ^"%#{search}%"))
  defp query_list_layouts_search(query, _search), do: query

  @doc """
  Returns all published layouts for `site`.

  Layouts are extracted from the latest published `Beacon.Content.LayoutSnapshot`.
  """
  @doc type: :layouts
  @spec list_published_layouts(Site.t()) :: [Layout.t()]
  def list_published_layouts(site) do
    Repo.all(
      from snapshot in LayoutSnapshot,
        join: event in LayoutEvent,
        on: snapshot.event_id == event.id,
        preload: [event: event],
        where: snapshot.site == ^site,
        where: event.event == :published,
        distinct: [asc: snapshot.layout_id],
        order_by: [desc: snapshot.inserted_at]
    )
    |> Enum.map(&extract_layout_snapshot/1)
  end

  @doc """
  Get latest published layout.
  """
  @doc type: :layouts
  @spec get_published_layout(Site.t(), Ecto.UUID.t()) :: Layout.t() | nil
  def get_published_layout(site, layout_id) do
    Repo.one(
      from snapshot in LayoutSnapshot,
        join: event in LayoutEvent,
        on: snapshot.event_id == event.id,
        preload: [event: event],
        where: snapshot.site == ^site,
        where: event.event == :published,
        where: event.layout_id == ^layout_id and snapshot.layout_id == ^layout_id,
        distinct: [asc: snapshot.layout_id],
        order_by: [desc: snapshot.inserted_at]
    )
    |> extract_layout_snapshot()
  end

  defp extract_layout_snapshot(%{schema_version: 1, layout: %Layout{} = layout}) do
    layout
    |> convert_body_to_template()
    |> convert_stylesheet_urls_to_resource_links()
  end

  defp extract_layout_snapshot(%{schema_version: 2, layout: %Layout{} = layout}) do
    convert_stylesheet_urls_to_resource_links(layout)
  end

  defp extract_layout_snapshot(%{schema_version: 3, layout: %Layout{} = layout}) do
    layout
  end

  defp extract_layout_snapshot(_snapshot), do: nil

  defp convert_body_to_template(layout) do
    {body, layout} = Map.pop(layout, :body)
    Map.put(layout, :template, body)
  end

  defp convert_stylesheet_urls_to_resource_links(layout) do
    {stylesheet_urls, layout} = Map.pop(layout, :stylesheet_urls)

    resource_links =
      Enum.map(stylesheet_urls, fn url ->
        %{
          rel: "stylesheet",
          href: url
        }
      end)

    Map.put(layout, :resource_links, resource_links)
  end

  # deprecated: to be removed
  @doc false
  def list_distinct_sites_from_layouts do
    Repo.all(from l in Layout, distinct: true, select: l.site, order_by: l.site)
  end

  ## PAGES

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking page changes.

  ## Example

      iex> change_page(page, %{title: "My Campaign"})
      %Ecto.Changeset{data: %Page{}}

  """
  @doc type: :pages
  @spec change_page(Page.t(), map()) :: Changeset.t()
  def change_page(%Page{} = page, attrs \\ %{}) do
    Page.create_changeset(page, attrs)
  end

  @doc """
  Validate `page` with the given `params`.

  All `Beacon.Content.PageField` are validated

  """
  @doc type: :pages
  @spec validate_page(Site.t(), Page.t(), map()) :: Changeset.t()
  def validate_page(site, %Page{} = page, attrs) when is_map(attrs) do
    {extra_attrs, page_attrs} = Map.pop(attrs, "extra")

    changeset =
      page
      |> change_page(page_attrs)
      |> Map.put(:action, :validate)

    PageField.apply_changesets(changeset, site, extra_attrs)
  end

  @doc """
  Creates a new page that's not published.

  ## Example

      iex> create_page(%{"title" => "My New Page"})
      {:ok, %Page{}}

  `attrs` may contain the following keys:

    * `path` - String.t()
    * `title` - String.t()
    * `description` - String.t()
    * `template` - String.t()
    * `meta_tags` - list(map()) eg: `[%{"property" => "og:title", "content" => "My New Siste"}]`

  See `Beacon.Content.Page` for more info.

  The created page is not published automatically,
  you can make as much changes you need and when the page
  is ready to be published you can call publish_page/1

  It will insert a `created` event into the page timeline,
  and no snapshot is created.
  """
  @doc type: :pages
  @spec create_page(map()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def create_page(attrs) when is_map(attrs) do
    changeset = Page.create_changeset(%Page{}, attrs)

    Repo.transact(fn ->
      with {:ok, changeset} <- validate_page_template(changeset),
           {:ok, page} <- Repo.insert(changeset),
           {:ok, _event} <- create_page_event(page, "created"),
           %Page{} = page <- Lifecycle.Page.after_create_page(page) do
        {:ok, page}
      end
    end)
  end

  @doc """
  Creates a page.
  """
  @doc type: :pages
  @spec create_page!(map()) :: Page.t()
  def create_page!(attrs) do
    case create_page(attrs) do
      {:ok, page} -> page
      {:error, changeset} -> raise "failed to create page, got: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  Updates a page.

  ## Example

      iex> update_page(page, %{title: "New Home"})
      {:ok, %Page{}}

  """
  @doc type: :pages
  @spec update_page(Page.t(), map()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def update_page(%Page{} = page, attrs) do
    {ast, attrs} = Map.pop(attrs, "ast")

    attrs =
      if is_nil(ast) do
        attrs
      else
        Map.put(attrs, :template, HEExDecoder.decode(ast))
      end

    changeset = Page.update_changeset(page, attrs)

    Repo.transact(fn ->
      with {:ok, changeset} <- validate_page_template(changeset),
           {:ok, page} <- Repo.update(changeset),
           %Page{} = page <- Lifecycle.Page.after_update_page(page) do
        {:ok, page}
      end
    end)
  end

  @doc """
  Publish `page`.

  A new snapshot is automatically created to store the page data,
  which is used whenever the site or the page is reloaded. So you
  can keep editing the page as needed without impacting the published page.
  """
  @doc type: :pages
  @spec publish_page(Page.t()) :: {:ok, Page.t()} | {:error, Changeset.t() | term()}
  def publish_page(%Page{} = page) do
    publish = fn page ->
      changeset = Page.update_changeset(page, %{})

      Repo.transact(fn ->
        with {:ok, _changeset} <- validate_page_template(changeset),
             {:ok, event} <- create_page_event(page, "published"),
             {:ok, _snapshot} <- create_page_snapshot(page, event),
             %Page{} = page <- Lifecycle.Page.after_publish_page(page) do
          {:ok, page}
        end
      end)
    end

    with {:ok, page} <- publish.(page),
         :ok <- PubSub.page_published(page) do
      {:ok, page}
    end
  end

  @doc type: :pages
  @spec publish_page(Ecto.UUID.t()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def publish_page(id) when is_binary(id) do
    id
    |> get_page()
    |> publish_page()
  end

  @doc """
  Publish multiple `pages`.

  Similar to `publish_page/1` but defers loading dependent resources
  as late as possible making the process faster.

  """
  @doc type: :pages
  @spec publish_pages([Page.t()]) :: {:ok, [Page.t()]}
  def publish_pages(pages) when is_list(pages) do
    publish = fn page ->
      Repo.transact(fn ->
        with {:ok, event} <- create_page_event(page, "published"),
             {:ok, _snapshot} <- create_page_snapshot(page, event) do
          {:ok, page}
        end
      end)
    end

    pages =
      pages
      |> Enum.map(&publish.(&1))
      |> Enum.map(fn
        {:ok, %Page{} = page} -> Lifecycle.Page.after_publish_page(page)
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    :ok = PubSub.pages_published(pages)
    {:ok, pages}
  end

  defp validate_page_template(changeset) do
    site = Changeset.get_field(changeset, :site)
    path = Changeset.get_field(changeset, :path, "nopath")
    format = Changeset.get_field(changeset, :format)
    template = Changeset.get_field(changeset, :template)
    metadata = %Beacon.Template.LoadMetadata{site: site, path: path}

    case do_validate_template(changeset, :template, format, template, metadata) do
      %Changeset{errors: []} = changeset -> {:ok, changeset}
      %Changeset{} = changeset -> {:error, changeset}
    end
  end

  @doc """
  Unpublish `page`.

  Note that page will be removed from your site
  and it will return error 404 for new requests.
  """
  @doc type: :pages
  @spec unpublish_page(Page.t()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def unpublish_page(%Page{} = page) do
    Repo.transact(fn ->
      with {:ok, _event} <- create_page_event(page, "unpublished") do
        # TODO: unload page
        :ok = PubSub.page_unpublished(page)
        {:ok, page}
      end
    end)
  end

  @doc false
  def create_page_event(page, event) do
    attrs = %{"site" => page.site, "page_id" => page.id, "event" => event}

    %PageEvent{}
    |> Changeset.cast(attrs, [:site, :page_id, :event])
    |> Changeset.validate_required([:site, :page_id, :event])
    |> Repo.insert()
  end

  @doc false
  def create_page_snapshot(page, event) do
    page = Repo.preload(page, [:variants, :event_handlers])
    attrs = %{"site" => page.site, "schema_version" => Page.version(), "page_id" => page.id, "page" => page, "event_id" => event.id}

    %PageSnapshot{}
    |> Changeset.cast(attrs, [:site, :schema_version, :page_id, :page, :event_id])
    |> Changeset.validate_required([:site, :schema_version, :page_id, :page, :event_id])
    |> Repo.insert()
  end

  @doc """
  Gets a single page by `id`.

  ## Options

    * `:preloads` - a list of preloads to load.

  ## Examples

      iex> get_page("dba8a99e-311a-4806-af04-dd968c7e5dae")
      %Page{}

      iex> get_page("dba8a99e-311a-4806-af04-dd968c7e5dae", preloads: [:layout])
      %Page{layout: %Layout{}}

  """
  @doc type: :pages
  @spec get_page(Ecto.UUID.t(), keyword()) :: Page.t() | nil
  def get_page(id, opts \\ []) when is_binary(id) and is_list(opts) do
    preloads = Keyword.get(opts, :preloads, [])

    Page
    |> Repo.get(id)
    |> Repo.preload(preloads)
  end

  @doc type: :pages
  def get_page!(id, opts \\ []) when is_binary(id) and is_list(opts) do
    case get_page(id, opts) do
      %Page{} = page -> page
      nil -> raise "page #{id} not found"
    end
  end

  @doc """
  Gets a single page by `clauses`.

  ## Example

      iex> get_page_by(site, path: "contact")
      %Page{}

  """
  @doc type: :pages
  @spec get_page_by(Site.t(), keyword(), keyword()) :: Page.t() | nil
  def get_page_by(site, clauses, opts \\ []) when is_atom(site) and is_list(clauses) do
    clauses = Keyword.put(clauses, :site, site)
    Repo.get_by(Page, clauses, opts)
  end

  @doc """
  Returns all page events with associated snapshot if available.

  ## Example

      iex> list_page_events(:my_site, page_id)
      [
        %PageEvent{event: :created, snapshot: nil},
        %PageEvent{event: :published, snapshot: %PageSnapshot{}}
      ]

  """
  @doc type: :pages
  @spec list_page_events(Site.t(), Ecto.UUID.t()) :: [PageEvent.t()]
  def list_page_events(site, page_id) when is_atom(site) and is_binary(page_id) do
    Repo.all(
      from event in PageEvent,
        left_join: snapshot in PageSnapshot,
        on: snapshot.event_id == event.id,
        where: event.site == ^site and event.page_id == ^page_id,
        preload: [snapshot: snapshot],
        order_by: [desc: event.inserted_at]
    )
  end

  @doc """
  Returns the latest page event.

  Useful to find the status of a page.

  ## Example

      iex> get_latest_page_event(:my_site, page_id)
      %PageEvent{event: :published}

  """
  @doc type: :pages
  @spec get_latest_page_event(Site.t(), Ecto.UUID.t()) :: PageEvent.t() | nil
  def get_latest_page_event(site, page_id) when is_atom(site) and is_binary(page_id) do
    Repo.one(
      from event in PageEvent,
        where: event.site == ^site and event.page_id == ^page_id,
        limit: 1,
        order_by: [desc: event.inserted_at]
    )
  end

  @doc """
  List pages.

  ## Options

    * `:per_page` - limit how many records are returned, or pass `:infinity` to return all records.
    * `:query` - search pages by path or title.
    * `:preloads` - a list of preloads to load.

  """
  @doc type: :pages
  @spec list_pages(Site.t(), keyword()) :: [Page.t()]
  def list_pages(site, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    search = Keyword.get(opts, :query)
    preloads = Keyword.get(opts, :preloads, [])

    site
    |> query_list_pages_base()
    |> query_list_pages_limit(per_page)
    |> query_list_pages_search(search)
    |> query_list_pages_preloads(preloads)
    |> Repo.all()
  end

  defp query_list_pages_base(site) do
    from p in Page,
      where: p.site == ^site,
      order_by: [asc: p.order, asc: fragment("length(?)", p.path)]
  end

  defp query_list_pages_limit(query, limit) when is_integer(limit), do: from(q in query, limit: ^limit)
  defp query_list_pages_limit(query, :infinity = _limit), do: query
  defp query_list_pages_limit(query, _per_page), do: from(q in query, limit: 20)

  defp query_list_pages_search(query, search) when is_binary(search) do
    from(q in query, where: ilike(q.path, ^"%#{search}%") or ilike(q.title, ^"%#{search}%"))
  end

  defp query_list_pages_search(query, _search), do: query

  defp query_list_pages_preloads(query, [_preload | _] = preloads) do
    from(q in query, preload: ^preloads)
  end

  defp query_list_pages_preloads(query, _preloads), do: query

  @doc """
  Returns all published pages for `site`.

  Unpublished pages are not returned even if it was once published before,
  only the latest status is valid.

  Pages are extracted from the latest published `Beacon.Content.PageSnapshot`.
  """
  @doc type: :pages
  @spec list_published_pages(Site.t()) :: [Layout.t()]
  def list_published_pages(site) do
    events =
      from event in PageEvent,
        where: event.site == ^site,
        distinct: [asc: event.page_id],
        order_by: fragment("inserted_at desc, case when event = 'published' then 0 else 1 end")

    Repo.all(
      from snapshot in PageSnapshot,
        join: event in subquery(events),
        on: snapshot.event_id == event.id,
        where: snapshot.site == ^site
    )
    |> Enum.map(&extract_page_snapshot/1)
  end

  @doc """
  Get latest published page.
  """
  @doc type: :pages
  @spec get_published_page(Site.t(), Ecto.UUID.t()) :: Page.t() | nil
  def get_published_page(site, page_id) do
    events =
      from event in PageEvent,
        where: event.site == ^site,
        where: event.page_id == ^page_id,
        distinct: [asc: event.page_id],
        order_by: [desc: event.inserted_at]

    Repo.one(
      from snapshot in PageSnapshot,
        join: event in subquery(events),
        on: snapshot.event_id == event.id,
        where: snapshot.site == ^site
    )
    |> extract_page_snapshot()
  end

  defp extract_page_snapshot(%{schema_version: 1, page: %Page{} = page}) do
    page
    |> Repo.reload()
    |> Repo.preload([:variants, :event_handlers], force: true)
  end

  defp extract_page_snapshot(%{schema_version: 2, page: %Page{} = page}) do
    page
    |> Repo.reload()
    |> Repo.preload(:event_handlers, force: true)
  end

  defp extract_page_snapshot(%{schema_version: 3, page: %Page{} = page}) do
    page
  end

  defp extract_page_snapshot(_snapshot), do: nil

  @doc """

  """
  @doc type: :pages
  @spec put_page_extra(Page.t(), map()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def put_page_extra(%Page{} = page, attrs) when is_map(attrs) do
    attrs = %{"extra" => attrs}

    page
    |> Changeset.cast(attrs, [:extra])
    |> Repo.update()
  end

  # STYLESHEETS

  @doc """
  Creates a stylesheet.

  ## Example

      iex> create_stylesheet(%{field: value})
      {:ok, %Stylesheet{}}

  """
  @doc type: :stylesheets
  @spec create_stylesheet(map()) :: {:ok, Stylesheet.t()} | {:error, Changeset.t()}
  def create_stylesheet(attrs \\ %{}) do
    %Stylesheet{}
    |> Stylesheet.changeset(attrs)
    |> Repo.insert()
  end

  @doc type: :stylesheets
  def create_stylesheet!(attrs \\ %{}) do
    case create_stylesheet(attrs) do
      {:ok, stylesheet} -> stylesheet
      {:error, changeset} -> raise "failed to create stylesheet, got: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  Updates a stylesheet.

  ## Example

      iex> update_stylesheet(stylesheet, %{name: new_value})
      {:ok, %Stylesheet{}}

  """
  @doc type: :stylesheets
  @spec update_stylesheet(Stylesheet.t(), map()) :: {:ok, Stylesheet.t()} | {:error, Changeset.t()}
  def update_stylesheet(%Stylesheet{} = stylesheet, attrs) do
    stylesheet
    |> Stylesheet.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets a single stylesheet by `clauses`.

  ## Example

      iex> get_stylesheet_by(site, name: "main")
      %Stylesheet{}

  """
  @doc type: :stylesheets
  @spec get_stylesheet_by(Site.t(), keyword(), keyword()) :: Stylesheet.t() | nil
  def get_stylesheet_by(site, clauses, opts \\ []) when is_atom(site) and is_list(clauses) do
    clauses = Keyword.put(clauses, :site, site)
    Repo.get_by(Stylesheet, clauses, opts)
  end

  @doc """
  Returns the list of stylesheets for `site`.

  ## Example

      iex> list_stylesheets()
      [%Stylesheet{}, ...]

  """
  @doc type: :stylesheets
  @spec list_stylesheets(Site.t()) :: [Stylesheet.t()]
  def list_stylesheets(site) do
    Repo.all(
      from s in Stylesheet,
        where: s.site == ^site
    )
  end

  # COMPONENTS

  @doc """
  Returns the list of components that are loaded into new sites.

  Those include basic elements like buttons and links as sample components like header and navbars.
  """
  @spec blueprint_components() :: [map()]
  @doc type: :components
  def blueprint_components do
    nav_1 = """
    <nav>
      <div class="flex justify-between px-8 py-5 bg-white">
        <div class="w-auto mr-14">
          <a href="#"><img src="https://shuffle.dev/gradia-assets/logos/gradia-name-black.svg" /></a>
        </div>
        <div class="w-auto flex flex-wrap items-center">
          <ul class="flex items-center mr-10">
            <li class="mr-9 text-gray-900 hover:text-gray-700 text-lg">
              <a href="#">Features</a>
            </li>
            <li class="mr-9 text-gray-900 hover:text-gray-700 text-lg">
              <a href="#">Solutions</a>
            </li>
            <li class="mr-9 text-gray-900 hover:text-gray-700 text-lg">
              <a href="#">Resources</a>
            </li>
            <li class="mr-9 text-gray-900 hover:text-gray-700 text-lg">
              <a href="#">Pricing</a>
            </li>
          </ul>
          <button class="text-white px-2 py-1 block w-full md:w-auto text-lg text-gray-900 font-medium overflow-hidden rounded-10 bg-blue-500 rounded">
            Start Free Trial
          </button>
        </div>
      </div>
    </nav>
    """

    nav_2 = """
    <nav>
      <div class="flex justify-between px-8 py-5 bg-white">
        <div class="w-auto mr-14">
          <a href="#">
            <img src="https://shuffle.dev/gradia-assets/logos/gradia-name-black.svg" />
          </a>
        </div>
        <div class="w-auto flex flex-wrap items-center">
          <ul class="flex items-center mr-10">
            <li class="mr-9 text-gray-900 hover:text-gray-700 text-lg">
              <a href="#">Features</a>
            </li>
            <li class="mr-9 text-gray-900 hover:text-gray-700 text-lg">
              <a href="#">Solutions</a>
            </li>
            <li class="mr-9 text-gray-900 hover:text-gray-700 text-lg">
              <a href="#">Resources</a>
            </li>
            <li class="mr-9 text-gray-900 hover:text-gray-700 text-lg">
              <a href="#">Pricing</a>
            </li>
          </ul>
        </div>
        <div class="w-auto flex flex-wrap items-center">
          <button class="text-white px-2 py-1 block w-full md:w-auto text-lg text-gray-900 font-medium overflow-hidden rounded-10 bg-blue-500 rounded">
            Start Free Trial
          </button>
        </div>
      </div>
    </nav>
    """

    header_1 = """
    <div class="container mx-auto px-4">
      <div class="max-w-xl">
        <span class="inline-block mb-3 text-gray-600 text-base">
          Flexible Pricing Plan
        </span>
        <h2 class="mb-16 font-heading font-bold text-6xl sm:text-7xl text-gray-900">
          Everything you need to launch a website
        </h2>
      </div>
      <div class="flex flex-wrap">
        <div class="w-full md:w-1/3">
          <div class="pt-8 px-11 xl:px-20 pb-10 bg-transparent border-b md:border-b-0 md:border-r border-gray-200 rounded-10">
            <h3 class="mb-0.5 font-heading font-semibold text-lg text-gray-900">
              Basic
            </h3>
            <p class="mb-5 text-gray-600 text-sm">
              Best for freelancers
            </p>
            <div class="mb-9 flex">
              <span class="mr-1 mt-0.5 font-heading font-semibold text-lg text-gray-900">$</span>
              <span class="font-heading font-semibold text-6xl sm:text-7xl text-gray-900">29</span>
              <span class="font-heading font-semibold self-end">/ m</span>
            </div>
            <div class="p-1">
              <button class="group relative mb-9 p-px w-full font-heading font-semibold text-xs text-gray-900 bg-gradient-green uppercase tracking-px overflow-hidden rounded-md">
                <div class="absolute top-0 left-0 transform -translate-y-full group-hover:-translate-y-0 h-full w-full bg-gradient-green transition ease-in-out duration-500">
                </div>
                <div class="p-4 bg-gray-50 overflow-hidden rounded-md">
                  <p class="relative z-10">
                    Join now
                  </p>
                </div>
              </button>
            </div>
            <ul>
              <li class="flex items-center font-heading mb-3 font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.0.0.4.0.0.0"
                  >
                  </path>
                </svg>
                <p>
                  100GB Cloud Storage
                </p>
              </li>
              <li class="flex items-center font-heading mb-3 font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.0.0.4.1.0.0"
                  >
                  </path>
                </svg>
                <p>
                  10 Email Connection
                </p>
              </li>
              <li class="flex items-center font-heading font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.0.0.4.2.0.0"
                  >
                  </path>
                </svg>
                <p>
                  Daily Analytics
                </p>
              </li>
            </ul>
          </div>
        </div>
        <div class="w-full md:w-1/3">
          <div class="pt-8 px-11 xl:px-20 pb-10 bg-transparent rounded-10">
            <h3 class="mb-0.5 font-heading font-semibold text-lg text-gray-900">
              Premium
            </h3>
            <p class="mb-5 text-gray-600 text-sm">
              Best for small agency
            </p>
            <div class="mb-9 flex">
              <span class="mr-1 mt-0.5 font-heading font-semibold text-lg text-gray-900">
                $
              </span>
              <span class="font-heading font-semibold text-6xl sm:text-7xl text-gray-900">
                99
              </span>
              <span class="font-heading font-semibold self-end">
                / m
              </span>
            </div>
            <div class="p-1">
              <button class="group relative mb-9 p-px w-full font-heading font-semibold text-xs text-gray-900 bg-gradient-green uppercase tracking-px overflow-hidden rounded-md">
                <div class="absolute top-0 left-0 transform -translate-y-full group-hover:-translate-y-0 h-full w-full bg-gradient-green transition ease-in-out duration-500">
                </div>
                <div class="p-4 bg-gray-50 overflow-hidden rounded-md">
                  <p class="relative z-10">Join now</p>
                </div>
              </button>
            </div>
            <ul>
              <li class="flex items-center font-heading mb-3 font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.1.0.4.0.0.0"
                  >
                  </path>
                </svg>
                <p>
                  500GB Cloud Storage
                </p>
              </li>
              <li class="flex items-center font-heading mb-3 font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.1.0.4.1.0.0"
                  >
                  </path>
                </svg>
                <p>
                  50 Email Connection
                </p>
              </li>
              <li class="flex items-center font-heading mb-3 font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.1.0.4.2.0.0"
                  >
                  </path>
                </svg>
                <p>
                  Daily Analytics
                </p>
              </li>
              <li class="flex items-center font-heading font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.1.0.4.3.0.0"
                  >
                  </path>
                </svg>
                <p>
                  Premium Support
                </p>
              </li>
            </ul>
          </div>
        </div>
        <div class="w-full md:w-1/3">
          <div class="relative pt-8 px-11 pb-10 bg-white rounded-10 shadow-8xl">
            <p class="absolute right-2 top-2 font-heading px-2.5 py-1 text-xs max-w-max bg-gray-100 uppercase tracking-px rounded-full text-gray-900">
              Popular choice
            </p>
            <h3 class="mb-0.5 font-heading font-semibold text-lg text-gray-900">
              Enterprise
            </h3>
            <p class="mb-5 text-gray-600 text-sm">
              Best for large agency
            </p>
            <div class="mb-9 flex">
              <span class="mr-1 mt-0.5 font-heading font-semibold text-lg text-gray-900">
                $
              </span>
              <span class="font-heading font-semibold text-6xl sm:text-7xl text-gray-900">
                199
              </span>
              <span class="font-heading font-semibold self-end">
                / m
              </span>
            </div>
            <div class="group relative mb-9">
              <div class="absolute top-0 left-0 w-full h-full bg-gradient-green opacity-0 group-hover:opacity-50 p-1 rounded-lg transition ease-out duration-300">
              </div>
              <button class="p-1 w-full font-heading font-semibold text-xs text-gray-900 uppercase tracking-px overflow-hidden rounded-md">
                <div class="relative z-10 p-4 bg-gradient-green overflow-hidden rounded-md">
                  <p>
                    Join now
                  </p>
                </div>
              </button>
            </div>
            <ul>
              <li class="flex items-center font-heading mb-3 font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.2.0.5.0.0.0"
                  >
                  </path>
                </svg>
                <p>
                  2TB Cloud Storage
                </p>
              </li>
              <li class="flex items-center font-heading mb-3 font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.2.0.5.1.0.0"
                  >
                  </path>
                </svg>
                <p>
                  Unlimited Email Connection
                </p>
              </li>
              <li class="flex items-center font-heading mb-3 font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.2.0.5.2.0.0"
                  >
                  </path>
                </svg>
                <p>
                  Daily Analytics
                </p>
              </li>
              <li class="flex items-center font-heading font-medium text-base text-gray-900">
                <svg class="mr-2.5">
                  <path
                    d="M4.58301 11.9167L8.24967 15.5834L17.4163 6.41669"
                    stroke="#A1A1AA"
                    stroke-width="1.5"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    data-path="0.0.1.2.0.5.3.0.0"
                  >
                  </path>
                </svg>
                <p>
                  Premium Support
                </p>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """

    [
      %{
        name: "Navigation 1",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/navigations/01_2be7c9d07f.png",
        body: nav_1,
        category: :nav
      },
      %{
        name: "Navigation 2",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/navigations/02_0f54c9f964.png",
        body: nav_2,
        category: :nav
      },
      %{
        name: "Navigation 3",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/navigations/03_e244675766.png",
        body: nav_1,
        category: :nav
      },
      %{
        name: "Navigation 4",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/navigations/04_64390b9975.png",
        body: nav_1,
        category: :nav
      },
      %{
        name: "Header 1",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/headers/01_b9f658e4b8.png",
        body: header_1,
        category: :header
      },
      %{
        name: "Header 2",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/headers/01_b9f658e4b8.png",
        body: "<div>Default definition for components</div>",
        category: :header
      },
      %{
        name: "Header 3",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/headers/01_b9f658e4b8.png",
        body: "<div>Default definition for components</div>",
        category: :header
      },
      %{
        name: "Sign Up 1",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/sign-up/01_c10e6e5d95.png",
        body: "<div>Default definition for components</div>",
        category: :sign_up
      },
      %{
        name: "Sign Up 2",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/sign-up/01_c10e6e5d95.png",
        body: "<div>Default definition for components</div>",
        category: :sign_up
      },
      %{
        name: "Sign Up 3",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/sign-up/01_c10e6e5d95.png",
        body: "<div>Default definition for components</div>",
        category: :sign_up
      },
      %{
        name: "Stats 1",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/numbers/01_204956d540.png",
        body: "<div>Default definition for components</div>",
        category: :stats
      },
      %{
        name: "Stats 2",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/numbers/01_204956d540.png",
        body: "<div>Default definition for components</div>",
        category: :stats
      },
      %{
        name: "Stats 3",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/numbers/01_204956d540.png",
        body: "<div>Default definition for components</div>",
        category: :stats
      },
      %{
        name: "Footer 1",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/footers/01_1648bd354f.png",
        body: "<div>Default definition for components</div>",
        category: :footer
      },
      %{
        name: "Footer 2",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/footers/01_1648bd354f.png",
        body: "<div>Default definition for components</div>",
        category: :footer
      },
      %{
        name: "Footer 3",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/footers/01_1648bd354f.png",
        body: "<div>Default definition for components</div>",
        category: :footer
      },
      %{
        name: "Sign In 1",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/sign-in/01_b25eff87e3.png",
        body: "<div>Default definition for components</div>",
        category: :sign_in
      },
      %{
        name: "Sign In 2",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/sign-in/01_b25eff87e3.png",
        body: "<div>Default definition for components</div>",
        category: :sign_in
      },
      %{
        name: "Sign In 3",
        thumbnail: "https://static.shuffle.dev/components/preview/43b384c1-17c4-470b-8332-d9dbb5ee99d7/sign-in/01_b25eff87e3.png",
        body: "<div>Default definition for components</div>",
        category: :sign_in
      },
      %{
        name: "Title",
        thumbnail: "/component_thumbnails/title.jpg",
        body: "<header>I'm a sample title</header>",
        category: :basic
      },
      %{
        name: "Button",
        thumbnail: "/component_thumbnails/button.jpg",
        body: "<button>I'm a sample button</button>",
        category: :basic
      },
      %{
        name: "Link",
        thumbnail: "/component_thumbnails/link.jpg",
        body: "<a href=\"#\">I'm a sample link</a>",
        category: :basic
      },
      %{
        name: "Paragraph",
        thumbnail: "/component_thumbnails/paragraph.jpg",
        body: "<p>I'm a sample paragraph</p>",
        category: :basic
      },
      %{
        name: "Aside",
        thumbnail: "/component_thumbnails/aside.jpg",
        body: "<aside>I'm a sample aside</aside>",
        category: :basic
      }
    ]
  end

  @doc """
  Returns a list of all existing component categories.
  """
  @doc type: :components
  @spec component_categories() :: [atom()]
  def component_categories, do: Component.categories()

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking component changes.

  ## Example

      iex> change_component(component, %{name: "Header"})
      %Ecto.Changeset{data: %Component{}}

  """
  @doc type: :components
  @spec change_component(Component.t(), map()) :: Changeset.t()
  def change_component(%Component{} = component, attrs \\ %{}) do
    Component.changeset(component, attrs)
  end

  @doc """
  Creates a component.

  ## Example

      iex> create_component(attrs)
      {:ok, %Component{}}

  """
  @spec create_component(map()) :: {:ok, Component.t()} | {:error, Changeset.t()}
  @doc type: :components
  def create_component(attrs \\ %{}) do
    %Component{}
    |> Component.changeset(attrs)
    |> validate_component_body()
    |> Repo.insert()
  end

  @doc type: :components
  def create_component!(attrs \\ %{}) do
    case create_component(attrs) do
      {:ok, component} -> component
      {:error, changeset} -> raise "failed to create component: #{inspect(changeset.errors)}"
    end
  end

  @doc """
  Updates a component.

      iex> update_component(component, %{name: "new_component"})
      {:ok, %Component{}}

  """
  @doc type: :components
  @spec update_component(Component.t(), map()) :: {:ok, Component.t()} | {:error, Changeset.t()}
  def update_component(%Component{} = component, attrs) do
    component
    |> Component.changeset(attrs)
    |> validate_component_body()
    |> Repo.update()
    |> tap(&maybe_reload_component/1)
  end

  def maybe_reload_component({:ok, component}), do: PubSub.component_updated(component)
  def maybe_reload_component({:error, _component}), do: :noop

  defp validate_component_body(changeset) do
    site = Changeset.get_field(changeset, :site)
    body = Changeset.get_field(changeset, :body)
    metadata = %Beacon.Template.LoadMetadata{site: site, path: "nopath"}
    do_validate_template(changeset, :body, :heex, body, metadata)
  end

  @doc """
  Gets a single component by `id`.

  ## Example

      iex> get_component("788b2161-b23a-48ed-abcd-8af788004bbb")
      %Component{}

  """
  @doc type: :components
  @spec get_component(Ecto.UUID.t()) :: Component.t() | nil
  def get_component(id) when is_binary(id) do
    Repo.get(Component, id)
  end

  @doc type: :components
  def get_component!(id) when is_binary(id) do
    Repo.get!(Component, id)
  end

  @doc """
  Gets a single component by `clauses`.

  ## Example

      iex> get_component_by(site, name: "header")
      %Component{}

  """
  @doc type: :components
  @spec get_component_by(Site.t(), keyword(), keyword()) :: Component.t() | nil
  def get_component_by(site, clauses, opts \\ []) when is_atom(site) and is_list(clauses) do
    clauses = Keyword.put(clauses, :site, site)
    Repo.get_by(Component, clauses, opts)
  end

  @doc """
  List components by `name`.

  ## Example

      iex> list_components_by_name(site, "header")
      [%Component{name: "header"}]

  """
  @doc type: :components
  @spec list_components_by_name(Site.t(), String.t()) :: [Component.t()]
  def list_components_by_name(site, name) when is_atom(site) and is_binary(name) do
    Repo.all(
      from c in Component,
        where: c.site == ^site and c.name == ^name
    )
  end

  @doc """
  List components.

  ## Options

    * `:per_page` - limit how many records are returned, or pass `:infinity` to return all records.
    * `:query` - search components by title.

  """
  @doc type: :components
  @spec list_components(Site.t(), keyword()) :: [Component.t()]
  def list_components(site, opts \\ []) do
    per_page = Keyword.get(opts, :per_page, 20)
    search = Keyword.get(opts, :query)

    site
    |> query_list_components_base()
    |> query_list_components_limit(per_page)
    |> query_list_components_search(search)
    |> Repo.all()
  end

  defp query_list_components_base(site) do
    from c in Component,
      where: c.site == ^site,
      order_by: [asc: c.name]
  end

  defp query_list_components_limit(query, limit) when is_integer(limit), do: from(q in query, limit: ^limit)
  defp query_list_components_limit(query, :infinity = _limit), do: query
  defp query_list_components_limit(query, _per_page), do: from(q in query, limit: 20)
  defp query_list_components_search(query, search) when is_binary(search), do: from(q in query, where: ilike(q.name, ^"%#{search}%"))
  defp query_list_components_search(query, _search), do: query

  # SNIPPETS

  @doc """
  Creates a snippet helper
  """
  @doc type: :snippets
  @spec create_snippet_helper(map()) :: {:ok, Snippets.Helper.t()} | {:error, Changeset.t()}
  def create_snippet_helper(attrs) do
    %Snippets.Helper{}
    |> Changeset.cast(attrs, [:site, :name, :body])
    |> Changeset.validate_required([:site, :name, :body])
    |> Changeset.unique_constraint([:site, :name])
    |> Repo.insert()
  end

  @doc type: :snippets
  def create_snippet_helper!(attrs) do
    case create_snippet_helper(attrs) do
      {:ok, helper} -> helper
      {:error, changeset} -> raise "failed to create snippet helper, got: #{inspect(changeset.errors)} "
    end
  end

  @doc """
  Returns the list of snippet helpers for a `site`.

  ## Example

      iex> list_snippet_helpers()
      [%SnippetHelper{}, ...]

  """
  @doc type: :snippets
  @spec list_snippet_helpers(Site.t()) :: [Snippets.Helper.t()]
  def list_snippet_helpers(site) do
    Repo.all(from h in Snippets.Helper, where: h.site == ^site)
  end

  @doc """
  Renders a snippet `template` with the given `assigns`.

  Snippets are small pieces of string with interpolated assigns.

  Think of it as small templates.

  ## Examples

      iex> Beacon.Content.render_snippet("title is {{ page.title }}", %{page: %Page{title: "home"}})
      {:ok, "title is home"}

  Snippets use the [Liquid](https://shopify.github.io/liquid/) template under the hood,
  which means that all [filters](https://shopify.github.io/liquid/basics/introduction/#filters) are available for use, eg:

      iex> Beacon.Content.render_snippet("{{ 'title' | capitalize }}", assigns)
      {:ok, "Title"}

  In situations where the Liquid filters are not enough, you can create helpers
  to process the template using regular Elixir.

  In the next example a `author_name` is created to simulate a query to fetch the author's name:

      iex> page = Beacon.Content.create_page(%{site: "my_site", extra: %{"author_id": 1}})
      iex> Beacon.Content.create_snippet_helper(%{site: "my_site", name: "author_name", body: ~S\"""
      ...> author_id = get_in(assigns, ["page", "extra", "author_id"])
      ...> MyApp.fetch_author_name(author_id)
      ...> \"""
      iex> Beacon.Snippet.render("Author is {{ helper 'author_name' }}", %{page: page})
      {:ok, "Author is Anon"}

  Note that the `:page` assigns is made available as `assigns["page"]` (String.t) due to how Solid works.

  Snipets can be used in:

    * Meta Tag value
    * Page Schema (structured Schema.org tags)

  Allowed assigns:

    * :page (Beacon.Content.Page.t())

  """
  @doc type: :snippets
  @spec render_snippet(String.t(), %{page: Page.t()}) :: {:ok, String.t()} | :error
  def render_snippet(template, assigns) when is_binary(template) and is_map(assigns) do
    page =
      assigns.page
      |> Map.from_struct()
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    assigns = %{"page" => page}

    with {:ok, template} <- Solid.parse(template, parser: Snippets.Parser),
         {:ok, template} <- Solid.render(template, assigns) do
      {:ok, to_string(template)}
    else
      # TODO: wrap error and return a Beacon exception
      _error -> :error
    end
  end

  # PAGE EVENT HANDLERS

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking event handler changes.

  ## Example

      iex> change_page_event_handler(page_event_handler, %{name: "form-submit"})
      %Ecto.Changeset{data: %PageEventHandler{}}

  """
  @doc type: :page_event_handlers
  @spec change_page_event_handler(PageEventHandler.t(), map()) :: Changeset.t()
  def change_page_event_handler(%PageEventHandler{} = event_handler, attrs \\ %{}) do
    PageEventHandler.changeset(event_handler, attrs)
  end

  @doc """
  Creates a new page event handler and returns the page with updated `:event_handlers` association.
  """
  @doc type: :page_event_handlers
  @spec create_event_handler_for_page(Page.t(), %{name: binary(), code: binary()}) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def create_event_handler_for_page(page, attrs) do
    changeset =
      page
      |> Ecto.build_assoc(:event_handlers)
      |> PageEventHandler.changeset(attrs)

    Repo.transact(fn ->
      with {:ok, %PageEventHandler{}} <- Repo.insert(changeset),
           %Page{} = page <- Repo.preload(page, :event_handlers, force: true),
           %Page{} = page <- Lifecycle.Page.after_update_page(page) do
        {:ok, page}
      end
    end)
  end

  @doc """
  Updates a page event handler and returns the page with updated `:event_handlers` association.
  """
  @doc type: :page_event_handlers
  @spec update_event_handler_for_page(Page.t(), PageEventHandler.t(), map()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def update_event_handler_for_page(page, event_handler, attrs) do
    changeset = PageEventHandler.changeset(event_handler, attrs)

    Repo.transact(fn ->
      with {:ok, %PageEventHandler{}} <- Repo.update(changeset),
           %Page{} = page <- Repo.preload(page, :event_handlers, force: true),
           %Page{} = page <- Lifecycle.Page.after_update_page(page) do
        {:ok, page}
      end
    end)
  end

  @doc """
  Deletes a page event handler and returns the page with updated `:event_handlers` association.
  """
  @doc type: :page_event_handlers
  @spec delete_event_handler_from_page(Page.t(), PageEventHandler.t()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def delete_event_handler_from_page(page, event_handler) do
    with {:ok, %PageEventHandler{}} <- Repo.delete(event_handler),
         %Page{} = page <- Repo.preload(page, :event_handlers, force: true),
         %Page{} = page <- Lifecycle.Page.after_update_page(page) do
      {:ok, page}
    end
  end

  # PAGE VARIANTS

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking variant changes.

  ## Example

      iex> change_page_variant(page_variant, %{name: "Variant A"})
      %Ecto.Changeset{data: %PageVariant{}}

  """
  @doc type: :page_variants
  @spec change_page_variant(PageVariant.t(), map()) :: Changeset.t()
  def change_page_variant(%PageVariant{} = variant, attrs \\ %{}) do
    PageVariant.changeset(variant, attrs)
  end

  @doc """
  Creates a new page variant and returns the page with updated `:variants` association.
  """
  @doc type: :page_variants
  @spec create_variant_for_page(Page.t(), %{name: binary(), template: binary(), weight: integer()}) ::
          {:ok, Page.t()} | {:error, Changeset.t()}
  def create_variant_for_page(page, attrs) do
    changeset =
      page
      |> Ecto.build_assoc(:variants)
      |> PageVariant.changeset(attrs)

    Repo.transact(fn ->
      with {:ok, %PageVariant{}} <- Repo.insert(changeset),
           %Page{} = page <- Repo.preload(page, :variants, force: true),
           %Page{} = page <- Lifecycle.Page.after_update_page(page) do
        {:ok, page}
      end
    end)
  end

  @doc """
  Updates a page variant and returns the page with updated `:variants` association.
  """
  @doc type: :page_variants
  @spec update_variant_for_page(Page.t(), PageVariant.t(), map()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def update_variant_for_page(page, variant, attrs) do
    changeset =
      variant
      |> PageVariant.changeset(attrs)
      |> validate_variant(page)

    Repo.transact(fn ->
      with {:ok, %PageVariant{}} <- Repo.update(changeset),
           %Page{} = page <- Repo.preload(page, :variants, force: true),
           %Page{} = page <- Lifecycle.Page.after_update_page(page) do
        {:ok, page}
      end
    end)
  end

  defp validate_variant(changeset, page) do
    %{format: format, site: site, path: path} = page = Repo.preload(page, :variants)
    template = Changeset.get_field(changeset, :template)
    metadata = %Beacon.Template.LoadMetadata{site: site, path: path}

    changeset
    |> do_validate_weights(page)
    |> do_validate_template(:template, format, template, metadata)
  end

  defp do_validate_weights(changeset, page) do
    Changeset.validate_change(changeset, :weight, fn :weight, changed_weight ->
      %{id: changed_variant_id} = changeset.data

      total_weights =
        Enum.reduce(page.variants, 0, fn
          %{id: ^changed_variant_id}, acc -> acc + changed_weight
          variant, acc -> acc + variant.weight
        end)

      if total_weights > 100 do
        [weight: "total weights cannot exceed 100"]
      else
        []
      end
    end)
  end

  @doc """
  Deletes a page variant and returns the page with updated variants association.
  """
  @doc type: :page_variants
  @spec delete_variant_from_page(Page.t(), PageVariant.t()) :: {:ok, Page.t()} | {:error, Changeset.t()}
  def delete_variant_from_page(page, variant) do
    with {:ok, %PageVariant{}} <- Repo.delete(variant),
         %Page{} = page <- Repo.preload(page, :variants, force: true),
         %Page{} = page <- Lifecycle.Page.after_update_page(page) do
      {:ok, page}
    end
  end

  ## Utils

  defp do_validate_template(changeset, field, _format, nil = _template, _metadata) do
    Changeset.add_error(changeset, field, "can't be blank", compilation_error: nil)
  end

  defp do_validate_template(changeset, field, :heex = _format, template, metadata) when is_binary(template) do
    Changeset.validate_change(changeset, field, fn ^field, template ->
      case Beacon.Template.HEEx.compile(template, metadata) do
        {:cont, _ast} -> []
        {:halt, %{description: description}} -> [{field, {"invalid", compilation_error: description}}]
        {:halt, _} -> [{field, "invalid"}]
      end
    end)
  end

  defp do_validate_template(changeset, field, :markdown = _format, template, metadata) when is_binary(template) do
    Changeset.validate_change(changeset, field, fn ^field, template ->
      case Beacon.Template.Markdown.convert_to_html(template, metadata) do
        {:cont, _template} -> []
        {:halt, %{message: message}} -> [{field, message}]
      end
    end)
  end

  # TODO: expose template validation to custom template formats defined by users
  defp do_validate_template(changeset, _field, _format, _template, _metadata), do: changeset
end

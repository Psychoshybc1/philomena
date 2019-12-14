defmodule Philomena.Tags do
  @moduledoc """
  The Tags context.
  """

  import Ecto.Query, warn: false
  alias Ecto.Multi
  alias Philomena.Repo

  alias Philomena.Tags.Tag
  alias Philomena.Tags.Uploader
  alias Philomena.Images
  alias Philomena.Images.Image
  alias Philomena.Users.User
  alias Philomena.Filters.Filter
  alias Philomena.Images.Tagging
  alias Philomena.UserLinks.UserLink
  alias Philomena.DnpEntries.DnpEntry

  @spec get_or_create_tags(String.t()) :: List.t()
  def get_or_create_tags(tag_list) do
    tag_names = Tag.parse_tag_list(tag_list)

    existent_tags =
      Tag
      |> where([t], t.name in ^tag_names)
      |> preload([:implied_tags, aliased_tag: :implied_tags])
      |> Repo.all()
      |> Enum.uniq_by(& &1.name)

    existent_tag_names =
      existent_tags
      |> Map.new(&{&1.name, true})

    nonexistent_tag_names =
      tag_names
      |> Enum.reject(&existent_tag_names[&1])

    # Now get rid of the aliases
    existent_tags =
      existent_tags
      |> Enum.map(& &1.aliased_tag || &1)

    new_tags =
      nonexistent_tag_names
      |> Enum.map(fn name ->
        {:ok, tag} =
          %Tag{}
          |> Tag.creation_changeset(%{name: name})
          |> Repo.insert()

        %{tag | implied_tags: []}
      end)

    new_tags
    |> reindex_tags()

    existent_tags ++ new_tags
  end

  @doc """
  Gets a single tag.

  Raises `Ecto.NoResultsError` if the Tag does not exist.

  ## Examples

      iex> get_tag!(123)
      %Tag{}

      iex> get_tag!(456)
      ** (Ecto.NoResultsError)

  """
  def get_tag!(slug), do: Repo.get_by!(Tag, slug: slug)

  @doc """
  Creates a tag.

  ## Examples

      iex> create_tag(%{field: value})
      {:ok, %Tag{}}

      iex> create_tag(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_tag(attrs \\ %{}) do
    %Tag{}
    |> Tag.creation_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a tag.

  ## Examples

      iex> update_tag(tag, %{field: new_value})
      {:ok, %Tag{}}

      iex> update_tag(tag, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_tag(%Tag{} = tag, attrs) do
    tag_input = Tag.parse_tag_list(attrs["implied_tag_list"])
    implied_tags =
      Tag
      |> where([t], t.name in ^tag_input)
      |> Repo.all()

    tag
    |> Tag.changeset(attrs, implied_tags)
    |> Repo.update()
  end

  def update_tag_image(%Tag{} = tag, attrs) do
    changeset = Uploader.analyze_upload(tag, attrs)

    Multi.new
    |> Multi.update(:tag, changeset)
    |> Multi.run(:update_file, fn _repo, %{tag: tag} ->
      Uploader.persist_upload(tag)
      Uploader.unpersist_old_upload(tag)

      {:ok, nil}
    end)
    |> Repo.isolated_transaction(:serializable)
  end

  def remove_tag_image(%Tag{} = tag) do
    changeset = Tag.remove_image_changeset(tag)

    Multi.new
    |> Multi.update(:tag, changeset)
    |> Multi.run(:remove_file, fn _repo, %{tag: tag} ->
      Uploader.unpersist_old_upload(tag)

      {:ok, nil}
    end)
    |> Repo.isolated_transaction(:serializable)
  end

  @doc """
  Deletes a Tag.

  ## Examples

      iex> delete_tag(tag)
      {:ok, %Tag{}}

      iex> delete_tag(tag)
      {:error, %Ecto.Changeset{}}

  """
  def delete_tag(%Tag{} = tag) do
    image_ids =
      Image
      |> join(:inner, [i], _ in assoc(i, :tags))
      |> where([_i, t], t.id == ^tag.id)
      |> select([i, _t], i.id)
      |> Repo.all()

    {:ok, _tag} = Repo.delete(tag)

    Image
    |> where([i], i.id in ^image_ids)
    |> preload(^Images.indexing_preloads())
    |> Image.reindex()
  end

  def alias_tag(%Tag{} = tag, attrs) do
    target_tag = Repo.get_by!(Tag, name: attrs["target_tag"])

    filters_hidden = where(Filter, [f], fragment("? @> ARRAY[?]", f.hidden_tag_ids, ^tag.id))
    filters_spoilered = where(Filter, [f], fragment("? @> ARRAY[?]", f.spoilered_tag_ids, ^tag.id))
    users_watching = where(User, [u], fragment("? @> ARRAY[?]", u.watched_tag_ids, ^tag.id))

    array_replace(filters_hidden, :hidden_tag_ids, tag.id, target_tag.id)
    array_replace(filters_spoilered, :spoilered_tag_ids, tag.id, target_tag.id)
    array_replace(users_watching, :watched_tag_ids, tag.id, target_tag.id)

    # Manual insert all because ecto won't do it for us
    Repo.query!(
      "INSERT INTO image_taggings (image_id, tag_id) " <>
      "SELECT i.id, #{target_tag.id} FROM images i " <>
      "INNER JOIN image_tagging it on it.image_id = i.id " <>
      "WHERE it.tag_id = #{tag.id} " <>
      "ON CONFLICT DO NOTHING"
    )

    # Delete taggings on the source tag
    Tagging
    |> where(tag_id: ^tag.id)
    |> Repo.delete_all()

    # Update other assocations
    UserLink
    |> where(tag_id: ^tag.id)
    |> Repo.update_all(set: [tag_id: target_tag.id])

    DnpEntry
    |> where(tag_id: ^tag.id)
    |> Repo.update_all(set: [tag_id: target_tag.id])

    # Update counters
    new_count =
      Image
      |> join(:inner, [i], _ in assoc(i, :tags))
      |> where([_i, t], t.id == ^target_tag.id)
      |> Repo.aggregate(:count, :id)

    Tag
    |> where(id: ^target_tag.id)
    |> Repo.update_all(set: [images_count: new_count])

    Tag
    |> where(id: ^tag.id)
    |> Repo.update_all(set: [images_count: 0, aliased_tag_id: target_tag.id, updated_at: DateTime.utc_now()])

    # Finally, update images
    Image
    |> join(:inner, [i], _ in assoc(i, :tags))
    |> where([_i, t], t.id == ^target_tag.id)
    |> preload(^Images.indexing_preloads())
    |> Image.reindex()
  end

  defp array_replace(queryable, column, old_value, new_value) do
    queryable
    |> update(
      [q],
      set: [
        {
          ^column,
          fragment("ARRAY(SELECT DISTINCT unnest(array_replace(?, ?, ?)) ORDER BY 1)", field(q, ^column), ^old_value, ^new_value)
        }
      ]
    )
    |> Repo.update_all([])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking tag changes.

  ## Examples

      iex> change_tag(tag)
      %Ecto.Changeset{source: %Tag{}}

  """
  def change_tag(%Tag{} = tag) do
    Tag.changeset(tag, %{})
  end

  def reindex_tag(%Tag{} = tag) do
    reindex_tags([%Tag{id: tag.id}])
  end

  def reindex_tags(tags) do
    spawn fn ->
      ids =
        tags
        |> Enum.map(& &1.id)

      Tag
      |> preload(^indexing_preloads())
      |> where([t], t.id in ^ids)
      |> Tag.reindex()
    end

    tags
  end

  def indexing_preloads do
    [:aliased_tag, :aliases, :implied_tags, :implied_by_tags]
  end

  alias Philomena.Tags.Implication

  @doc """
  Returns the list of tags_implied_tags.

  ## Examples

      iex> list_tags_implied_tags()
      [%Implication{}, ...]

  """
  def list_tags_implied_tags do
    Repo.all(Implication)
  end

  @doc """
  Gets a single implication.

  Raises `Ecto.NoResultsError` if the Implication does not exist.

  ## Examples

      iex> get_implication!(123)
      %Implication{}

      iex> get_implication!(456)
      ** (Ecto.NoResultsError)

  """
  def get_implication!(id), do: Repo.get!(Implication, id)

  @doc """
  Creates a implication.

  ## Examples

      iex> create_implication(%{field: value})
      {:ok, %Implication{}}

      iex> create_implication(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_implication(attrs \\ %{}) do
    %Implication{}
    |> Implication.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a implication.

  ## Examples

      iex> update_implication(implication, %{field: new_value})
      {:ok, %Implication{}}

      iex> update_implication(implication, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_implication(%Implication{} = implication, attrs) do
    implication
    |> Implication.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Implication.

  ## Examples

      iex> delete_implication(implication)
      {:ok, %Implication{}}

      iex> delete_implication(implication)
      {:error, %Ecto.Changeset{}}

  """
  def delete_implication(%Implication{} = implication) do
    Repo.delete(implication)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking implication changes.

  ## Examples

      iex> change_implication(implication)
      %Ecto.Changeset{source: %Implication{}}

  """
  def change_implication(%Implication{} = implication) do
    Implication.changeset(implication, %{})
  end
end

defmodule Hexpm.Web.API.ReleaseController do
  use Hexpm.Web, :controller

  plug :maybe_fetch_release when action in [:show]
  plug :fetch_release when action in [:delete]
  plug :maybe_fetch_package when action in [:create]
  plug :maybe_authorize, [domain: :api, fun: &repository_access?/2] when action in [:show]
  plug :authorize, [domain: :api, fun: &package_owner?/2] when action in [:delete]
  plug :authorize, [domain: :api, fun: &maybe_package_owner?/2] when action in [:create]

  def create(conn, %{"body" => body}) do
    handle_tarball(conn, conn.assigns.repository, conn.assigns.package, conn.assigns.current_user, body)
  end

  def show(conn, _params) do
    if release = conn.assigns.release do
      release = Releases.preload(release)

      when_stale(conn, release, fn conn ->
        conn
        |> api_cache(:public)
        |> render(:show, release: release)
      end)
    else
      not_found(conn)
    end
  end

  def delete(conn, _params) do
    package = conn.assigns.package
    release = conn.assigns.release

    case Releases.revert(package, release, audit: audit_data(conn)) do
      :ok ->
        conn
        |> api_cache(:private)
        |> send_resp(204, "")
      {:error, _, changeset, _} ->
        validation_failed(conn, changeset)
    end
  end

  defp handle_tarball(conn, repository, package, user, body) do
    case :hex_tar.unpack({:binary, body}) do
      {:ok, {checksum, meta, _files}} ->
        checksum = List.to_string(checksum)
        Releases.publish(repository, package, user, body, meta, checksum, audit: audit_data(conn))

      {:error, errors} ->
        {:error, %{tar: errors}}
    end
    |> publish_result(conn)
  end

  defp publish_result({:ok, %{action: :insert, package: package, release: release}}, conn) do
    location = api_release_url(conn, :show, package, release)

    conn
    |> put_resp_header("location", location)
    |> api_cache(:public)
    |> put_status(201)
    |> render(:show, release: release)
  end
  defp publish_result({:ok, %{action: :update, release: release}}, conn) do
    conn
    |> api_cache(:public)
    |> render(:show, release: release)
  end
  defp publish_result({:error, errors}, conn) do
    validation_failed(conn, errors)
  end
  defp publish_result({:error, _, changeset, _}, conn) do
    validation_failed(conn, normalize_errors(changeset))
  end

  defp normalize_errors(%{changes: %{requirements: requirements}} = changeset) do
    requirements =
      Enum.map(requirements, fn
        %{errors: errors} = req ->
          name = Ecto.Changeset.get_field(req, :name)
          %{req | errors: for({_, v} <- errors, do: {name, v}, into: %{})}
      end)

    put_in(changeset.changes.requirements, requirements)
  end
  defp normalize_errors(changeset), do: changeset
end

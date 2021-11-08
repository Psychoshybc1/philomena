defmodule PhilomenaWeb.LayoutPlug do
  @moduledoc """
  This plug stores the current site-wide layout attributes.

  ## Example

      plug PhilomenaWeb.LayoutPlug
  """

  alias Canada.Can
  alias Philomena.Layouts
  import Plug.Conn

  @doc false
  @spec init(any()) :: any()
  def init(opts), do: opts

  @doc false
  @spec call(Plug.Conn.t(), any()) :: Plug.Conn.t()
  def call(conn, _opts) do
    user = conn.assigns.current_user
    layout = Layouts.get_layout!()

    conn
    |> assign(:artist_link_count, layout.duplicate_report_count)
    |> assign(:dnp_entry_count, layout.dnp_entry_count)
    |> assign(:duplicate_report_count, layout.duplicate_report_count)
    |> assign(:live_channels, layout.channel_count)
    |> assign(:report_count, layout.report_count)
    |> assign(:forums, visible_forums(user, layout.forums))
    |> assign(:site_notices, site_notices(layout.site_notices))
  end

  defp visible_forums(user, forum_list) do
    forum_list
    |> Enum.filter(&Can.can?(user, :show, &1))
    |> Enum.sort_by(& &1.name)
  end

  defp site_notices(notice_list) do
    Enum.sort_by(notice_list, & &1.start_date, Date)
  end
end

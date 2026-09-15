defmodule JukeboxWeb.PageController do
  use JukeboxWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

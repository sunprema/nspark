defmodule NsparkWeb.PageController do
  use NsparkWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

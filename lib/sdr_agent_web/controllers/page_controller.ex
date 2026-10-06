defmodule SdrAgentWeb.PageController do
  use SdrAgentWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end

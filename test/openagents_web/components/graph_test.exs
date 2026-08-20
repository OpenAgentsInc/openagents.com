defmodule OpenAgentsWeb.UI.GraphTest do
  @moduledoc """
  The geometry is the part that can be silently wrong: a link terminating a few
  units inside a node still *looks* plausible. These assert the boundary
  condition directly, at many angles, rather than eyeballing one rendering.
  """

  use ExUnit.Case, async: true

  alias OpenAgentsWeb.UI.Graph

  describe "unit_vector/2" do
    test "is a unit vector for arbitrary separations" do
      for {a, b} <- [
            {{0.0, 0.0}, {3.0, 4.0}},
            {{-5.0, 2.0}, {7.0, -9.0}},
            {{1.0, 1.0}, {1.0, 9.0}}
          ] do
        {ux, uy} = Graph.unit_vector(a, b)
        assert_in_delta :math.sqrt(ux * ux + uy * uy), 1.0, 1.0e-9
      end
    end

    test "coincident points yield no direction rather than dividing by zero" do
      assert Graph.unit_vector({4.0, 4.0}, {4.0, 4.0}) == {0.0, 0.0}
    end
  end

  describe "surface_point/3" do
    test "a circle's surface point is exactly one radius from its centre" do
      node = %{shape: :circle, x: 10.0, y: 20.0, r: 7.0}

      for degrees <- 0..359//7 do
        rad = degrees * :math.pi() / 180.0
        u = {:math.cos(rad), :math.sin(rad)}
        {x, y} = Graph.surface_point(node, u)

        dx = x - node.x
        dy = y - node.y
        assert_in_delta :math.sqrt(dx * dx + dy * dy), node.r, 1.0e-9
      end
    end

    test "padding pushes the point outward by exactly that much" do
      node = %{shape: :circle, x: 0.0, y: 0.0, r: 5.0}
      {x, _} = Graph.surface_point(node, {1.0, 0.0}, 3)
      assert_in_delta x, 8.0, 1.0e-9
    end

    test "a rect's surface point lands on the boundary, never inside it" do
      node = %{shape: :rect, x: 0.0, y: 0.0, width: 20.0, height: 10.0}

      for degrees <- 0..359//5 do
        rad = degrees * :math.pi() / 180.0
        {x, y} = Graph.surface_point(node, {:math.cos(rad), :math.sin(rad)})

        on_x = abs(abs(x) - 10.0) < 1.0e-9 and abs(y) <= 5.0 + 1.0e-9
        on_y = abs(abs(y) - 5.0) < 1.0e-9 and abs(x) <= 10.0 + 1.0e-9

        assert on_x or on_y, "#{degrees} deg gave {#{x}, #{y}}, not on the boundary"
      end
    end

    test "an axis-aligned vector does not divide by a zero component" do
      node = %{shape: :rect, x: 0.0, y: 0.0, width: 8.0, height: 6.0}
      assert {+0.0, 3.0} = Graph.surface_point(node, {0.0, 1.0})
      assert {4.0, +0.0} = Graph.surface_point(node, {1.0, 0.0})
    end
  end

  describe "link_distance/1" do
    test "proximity encodes kind, matching Unit's ratios" do
      base = Graph.link_distance()

      assert Graph.link_distance(:type) == base / 2
      assert Graph.link_distance(:data) == base / 2
      assert Graph.link_distance(:error) == base * 7 / 8
      assert Graph.link_distance(:exposed) == base * 2 / 3
      assert Graph.link_distance(:normal) == base

      assert Graph.link_distance(:error) < Graph.link_distance(:normal)
    end
  end

  describe "the state taxonomy" do
    test "covers the SCV lifecycle from docs/scv-planning.md" do
      assert Graph.statuses() == [:idle, :running, :paused, :circuit_open, :disabled]
    end

    test "covers the work-item lifecycle from docs/scv-planning.md" do
      assert Graph.item_statuses() ==
               [:discovered, :admitted, :running, :completed, :deferred, :refused, :failed]
    end

    test "every rendered status has a style rule in the style pack" do
      css = File.read!("assets/css/openagents.css")

      for status <- Graph.statuses() ++ Graph.item_statuses() do
        assert css =~ ~s([data-status="#{status}"]),
               "#{status} renders but has no style rule, so it would be indistinguishable"
      end

      for kind <- Graph.link_kinds() -- [:normal] do
        assert css =~ ~s([data-kind="#{kind}"]), "link kind #{kind} has no style rule"
      end
    end
  end

  describe "describe_arc/5" do
    test "produces a valid arc command" do
      assert Graph.describe_arc(6.0, 6.0, 5.0, 210, 330) =~
               ~r/^M [\d.-]+ [\d.-]+ A 5\.0 5\.0 0 0 0/
    end
  end
end

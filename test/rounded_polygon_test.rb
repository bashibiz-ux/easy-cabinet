# frozen_string_literal: true

# The rounded-edge corner slab: the faces must close up into a solid. Run:  ruby test/rounded_polygon_test.rb

require 'minitest/autorun'
require_relative 'geom_stub'

module Sketchup
  class ComponentInstance; end
end
module EasyCabinet
  DATA_DIR = 'unused'
  module AttributeManager; end
  module MaterialManager; end
end
require File.expand_path('../easy_cabinet/panel_generator', __dir__)

class RoundedPolygonTest < Minitest::Test
  PG = EasyCabinet::PanelGenerator
  CORNER = [[0.0, 0.0], [0.0, 900.0], [800.0, 900.0], [900.0, 800.0], [900.0, 0.0]].freeze

  def key(point) = point.map { |v| v.round(6) }

  def faces(points = CORNER, radius = 10.0, edge = 2) = PG.rounded_polygon_faces(points, 20.0, radius, edge)

  def test_every_edge_belongs_to_exactly_two_faces
    edges = Hash.new(0)
    faces.each do |face|
      face.each_with_index { |p, i| edges[[key(p), key(face[(i + 1) % face.length])].sort] += 1 }
    end
    assert_empty edges.reject { |_e, n| n == 2 }.keys, 'an open edge or an edge shared by three faces'
  end

  def test_every_face_is_flat
    faces.each do |face|
      next if face.length < 4

      a, b, c = face
      normal = cross(sub(b, a), sub(c, a))
      length = Math.sqrt(dot(normal, normal))
      next if length < 1e-9

      face.each { |p| assert_in_delta 0.0, dot(sub(p, a), normal) / length, 1e-6 }
    end
  end

  def test_the_solid_has_the_volume_of_the_outline_less_the_rounding
    area = CORNER.each_with_index.sum { |(x, y), i| nx, ny = CORNER[(i + 1) % 5]; (x * ny) - (nx * y) }.abs / 2.0
    solid = fan_volume(faces)
    assert_operator solid, :<, area * 20.0, 'the rounding takes material off'
    assert_operator solid, :>, (area * 20.0) - (139.0 * 20.0 * 10.0), 'but not much'
  end

  def test_a_square_edge_gives_the_plain_slab
    assert_in_delta 900.0 * 900.0 * 20.0 - 100.0 * 100.0 / 2.0 * 20.0, fan_volume(faces(CORNER, 0.0)), 1e-3
  end

  def test_faces_point_outwards
    solid = fan_volume(faces)
    assert_operator solid, :>, 0.0, 'a positive volume means the faces point outwards'
  end

  # An L worktop: its two front edges (points 2 to 3 and 3 to 4) rounded.
  L_SHAPE = [[0.0, 0.0], [0.0, 1000.0], [600.0, 1000.0], [600.0, 600.0], [1000.0, 600.0], [1000.0, 0.0]].freeze

  def l_faces(radius = 10.0, edges = [2, 3]) = PG.rounded_polygon_faces(L_SHAPE, 20.0, radius, edges)

  def test_an_l_with_two_rounded_fronts_is_a_closed_solid
    edges = Hash.new(0)
    l_faces.each { |face| face.each_with_index { |p, i| edges[[key(p), key(face[(i + 1) % face.length])].sort] += 1 } }
    assert_empty edges.reject { |_e, n| n == 2 }.keys
  end

  def test_the_l_faces_are_flat_and_point_outwards_and_the_rounding_takes_a_little_off
    l_faces.each do |face|
      next if face.length < 4

      a, b, c = face
      normal = cross(sub(b, a), sub(c, a))
      length = Math.sqrt(dot(normal, normal))
      next if length < 1e-9

      face.each { |p| assert_in_delta 0.0, dot(sub(p, a), normal) / length, 1e-6 }
    end
    area = L_SHAPE.each_with_index.sum { |(x, y), i| nx, ny = L_SHAPE[(i + 1) % 6]; (x * ny) - (nx * y) }.abs / 2.0
    solid = fan_volume(l_faces)
    assert_operator solid, :>, 0.0
    assert_operator solid, :<, area * 20.0
    assert_operator solid, :>, (area * 20.0) - (1000.0 * 20.0 * 10.0), 'only the edges lose material'
    assert_in_delta area * 20.0, fan_volume(l_faces(0.0)), 1e-3, 'a square edge gives the plain L'
  end

  def test_the_two_fronts_meet_in_the_inside_corner
    top = l_faces.find { |face| face.all? { |p| (p[2] - 20.0).abs < 1e-9 } }
    corner = top.min_by { |p| ((p[0] - 590.0)**2) + ((p[1] - 590.0)**2) }
    assert_in_delta 590.0, corner[0], 1e-6, 'the top face is pulled in by the radius at the corner of both fronts'
    assert_in_delta 590.0, corner[1], 1e-6
  end

  def test_holes_make_a_name_of_their_own
    assert_equal '', PG.hole_suffix(nil)
    assert_equal '', PG.hole_suffix([])
    refute_equal PG.hole_suffix([[1.0, 2.0, 3.0, 4.0]]), PG.hole_suffix([[1.0, 2.0, 3.0, 5.0]])
  end

  private

  def sub(a, b) = [a[0] - b[0], a[1] - b[1], a[2] - b[2]]
  def dot(a, b) = (a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2])
  def cross(a, b) = [(a[1] * b[2]) - (a[2] * b[1]), (a[2] * b[0]) - (a[0] * b[2]), (a[0] * b[1]) - (a[1] * b[0])]

  # Signed volume: each face split into a fan of triangles against the origin.
  def fan_volume(faces)
    faces.sum do |face|
      (1...(face.length - 1)).sum { |i| dot(face[0], cross(face[i], face[i + 1])) / 6.0 }
    end
  end
end
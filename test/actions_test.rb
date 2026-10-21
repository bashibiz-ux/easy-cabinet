# frozen_string_literal: true

# Every action CabinetManager and PartManager answer to must be routed by the
# panel's DialogManager, or the panel shows 'Unknown action'.
# Run:  ruby test/actions_test.rb

require 'minitest/autorun'

class ActionsTest < Minitest::Test
  PLUGIN = File.expand_path('../easy_cabinet', __dir__)

  def source(name) = File.read(File.join(PLUGIN, name), encoding: 'UTF-8')

  def handled(file)
    source(file)[/def self\.perform\(action, raw\)(.*?)\n    end\n/m, 1].scan(/when '(\w+)'/).flatten
  end

  def routed(constant)
    source('dialog_manager.rb')[/#{constant} = %w\[([^\]]*)\]/, 1].split
  end

  def test_every_cabinet_action_is_routed
    assert_equal handled('cabinet_manager.rb').sort, routed('CABINET_ACTIONS').sort
  end

  def test_every_part_action_is_routed
    assert_equal handled('part_manager.rb').sort, routed('PART_ACTIONS').sort
  end

  def test_every_worktop_action_is_handled
    handled = source('worktop_manager.rb')[/def self\.perform\(action, raw\)(.*?)\n    end\n/m, 1].scan(/when '(\w+)'/).flatten
    assert_equal handled.sort, routed('WORKTOP_ACTIONS').sort
  end

  def test_every_room_action_is_handled
    handled = source('room_shell.rb')[/def self\.perform\(action, raw\)(.*?)\n    end\n/m, 1].scan(/when '(\w+)'/).flatten
    assert_equal handled.sort, routed('ROOM_ACTIONS').sort
  end

  def test_every_cut_list_action_is_handled
    handled = source('cut_list_manager.rb')[/def self\.perform\(action, raw\)(.*?)\n    end\n/m, 1].scan(/when '(\w+)'/).flatten
    assert_equal handled.sort, routed('CUT_LIST_ACTIONS').sort
  end

  def test_every_preset_action_is_handled
    handled = source('preset_manager.rb')[/def self\.perform\(action, raw\)(.*?)\n    end\n/m, 1].scan(/when '(\w+)'/).flatten
    assert_equal handled.sort, routed('PRESET_ACTIONS').sort
  end

  def test_every_action_the_panel_calls_is_routed
    known = routed('CABINET_ACTIONS') + routed('PART_ACTIONS') + routed('WORKTOP_ACTIONS') + routed('ROOM_ACTIONS') + routed('LIVE_ACTIONS') + routed('CUT_LIST_ACTIONS') + routed('PRESET_ACTIONS') + %w[init get_cabinets get_materials undo set_snap send_feedback open_donation add_material remove_material]
    sent = source('html/app.js').scan(/call\('(\w+)'/).flatten.uniq
    assert_empty sent - known, 'the panel calls actions Ruby does not know'
  end
end
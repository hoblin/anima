# frozen_string_literal: true

require_relative "../../lib/tui/height_map"

RSpec.describe TUI::HeightMap do
  subject(:map) { described_class.new }

  describe "#update" do
    it "stores heights from estimator block" do
      entries = [{type: :a}, {type: :b}, {type: :c}]
      map.update(entries, 80) { |_, _| 5 }

      expect(map.total_height).to eq(15)
      expect(map.size).to eq(3)
    end

    it "enforces minimum height of 1 per entry" do
      entries = [{type: :x}]
      map.update(entries, 80) { |_, _| 0 }

      expect(map.total_height).to eq(1)
    end

    it "replaces previous heights on re-update" do
      entries = [{type: :a}, {type: :b}]
      map.update(entries, 80) { |_, _| 3 }
      expect(map.total_height).to eq(6)

      map.update(entries, 80) { |_, _| 10 }
      expect(map.total_height).to eq(20)
    end

    it "passes entry and width to estimator" do
      entries = [{len: 200}, {len: 50}]
      map.update(entries, 80) { |entry, width| (entry[:len].to_f / width).ceil }

      expect(map.total_height).to eq(4) # ceil(200/80)=3, ceil(50/80)=1
    end
  end

  describe "#total_height" do
    it "returns 0 for empty map" do
      expect(map.total_height).to eq(0)
    end
  end

  describe "#cumulative_height" do
    before do
      entries = [{h: 3}, {h: 5}, {h: 7}, {h: 2}]
      map.update(entries, 80) { |e, _| e[:h] }
    end

    it "returns 0 for index 0" do
      expect(map.cumulative_height(0)).to eq(0)
    end

    it "returns height of first entry for index 1" do
      expect(map.cumulative_height(1)).to eq(3)
    end

    it "accumulates heights correctly" do
      expect(map.cumulative_height(2)).to eq(8)  # 3 + 5
      expect(map.cumulative_height(3)).to eq(15) # 3 + 5 + 7
    end

    it "sums all entries for index equal to size" do
      expect(map.cumulative_height(4)).to eq(17) # 3 + 5 + 7 + 2
    end

    it "clamps at total for index beyond size" do
      expect(map.cumulative_height(10)).to eq(17)
    end

    it "returns 0 for negative index" do
      expect(map.cumulative_height(-1)).to eq(0)
    end

    it "returns 0 for empty map" do
      empty_map = described_class.new
      expect(empty_map.cumulative_height(5)).to eq(0)
    end
  end

  describe "#visible_range" do
    context "with uniform 10-line entries" do
      before do
        entries = Array.new(10) { {h: 10} }
        map.update(entries, 80) { |e, _| e[:h] }
      end

      it "returns first entries when scrolled to top" do
        first, last = map.visible_range(0, 25)
        expect(first).to eq(0)
        expect(last).to eq(2) # lines 0-30 cover viewport 0-25
      end

      it "returns middle entries for mid-scroll" do
        first, last = map.visible_range(45, 25)
        expect(first).to eq(4)  # entry 4 starts at line 40
        expect(last).to eq(6)   # entry 6 ends at line 70, visible up to 70
      end

      it "returns last entries at bottom" do
        first, last = map.visible_range(75, 25)
        expect(first).to eq(7)
        expect(last).to eq(9)
      end

      it "includes entry that spans the viewport boundary" do
        # Viewport at line 9-34: entry 0 (0-10) overlaps at line 9
        first, _ = map.visible_range(9, 25)
        expect(first).to eq(0)
      end
    end

    context "with variable-height entries" do
      before do
        entries = [{h: 2}, {h: 30}, {h: 5}, {h: 3}]
        map.update(entries, 80) { |e, _| e[:h] }
      end

      it "handles a large entry spanning the entire viewport" do
        # Entry 1 is 30 lines (at offset 2-32). Viewport 5-25 is inside it.
        first, last = map.visible_range(5, 20)
        expect(first).to eq(1)
        expect(last).to eq(1) # only entry 1 covers the viewport
      end

      it "includes partial overlap at top" do
        # Entry 1 ends at line 32. Viewport at 31-51 starts in entry 1.
        first, _ = map.visible_range(31, 20)
        expect(first).to eq(1) # entry 1 ends at 32, partially visible
      end
    end

    it "returns [0, 0] for empty map" do
      expect(map.visible_range(0, 25)).to eq([0, 0])
    end

    it "handles single entry" do
      map.update([{h: 50}], 80) { |e, _| e[:h] }
      expect(map.visible_range(0, 25)).to eq([0, 0])
      expect(map.visible_range(25, 25)).to eq([0, 0])
    end

    it "guarantees last >= first" do
      entries = Array.new(5) { {h: 3} }
      map.update(entries, 80) { |e, _| e[:h] }

      first, last = map.visible_range(100, 25) # scroll past end
      expect(last).to be >= first
    end
  end

  describe "#reset" do
    it "clears all state" do
      entries = [{h: 5}, {h: 10}]
      map.update(entries, 80) { |e, _| e[:h] }

      map.reset

      expect(map.total_height).to eq(0)
      expect(map.size).to eq(0)
      expect(map.visible_range(0, 25)).to eq([0, 0])
    end
  end
end

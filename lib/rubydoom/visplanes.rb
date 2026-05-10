module Rubydoom
  # Accumulates visible floor / ceiling spans during wall rendering and
  # rasterizes them at end of frame.
  #
  # Spans of the same flat at the same world height with the same light
  # level get grouped into one Plane. Within a plane, each screen column
  # holds a *list* of [top_y, bot_y] inclusive ranges — not a single
  # bounding range — because non-convex sectors split by the BSP can
  # produce non-contiguous visible spans in a single column (e.g. the
  # pool floor in E1M1's zigzag room is visible both in the foreground
  # and again through gaps between the platforms behind them).
  # Collapsing those into one range would overwrite the wall pixels in
  # the gap when the visplane rasterizes.
  #
  # Adjacent / overlapping ranges added in sequence get merged in place
  # so the common contiguous case stays a single range — only genuinely
  # disjoint additions create a second list entry.
  class Visplanes
    Plane = Struct.new(:flat, :height, :light, :ceiling, :columns) do
      def add(sx, top, bot)
        list = columns[sx] ||= []
        # Merge with an existing range if the new span is overlapping or
        # immediately adjacent. Otherwise append as a separate range.
        list.each_with_index do |range, i|
          if top <= range[1] + 1 && bot >= range[0] - 1
            list[i] = [
              range[0] < top ? range[0] : top,
              range[1] > bot ? range[1] : bot,
            ]
            return
          end
        end
        list << [top, bot]
      end
    end

    def initialize(width)
      @width   = width
      @planes  = []
      @by_key  = {}
    end

    def add_span(flat, height, light, is_ceiling, sx, top, bot)
      return if flat.nil? || top > bot
      key = [flat.object_id, height, light, is_ceiling]
      plane = @by_key[key] ||= begin
        p = Plane.new(flat, height, light, is_ceiling, Array.new(@width))
        @planes << p
        p
      end
      plane.add(sx, top, bot)
    end

    def each_plane(&block)
      @planes.each(&block)
    end
  end
end

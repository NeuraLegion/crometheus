require "./metric"
require "./exceptions"

lib LibC
  fun getpagesize : Int
end

module Crometheus
  abstract class Metric
  end

  # A `Metric` type that reports basic process statistics as given by
  # Crystal.
  # Generated by `Crometheus.make_standard_exports`.
  class StandardExports < Metric
    @start_time : Float64?

    def self.type
      Type::Gauge
    end

    def samples
      tms = Process.times
      gc_stats = GC.stats
      yield Sample.new(gc_stats.heap_size.to_f, suffix: "gc_heap_bytes")
      yield Sample.new(gc_stats.free_bytes.to_f, suffix: "gc_free_bytes")
      yield Sample.new(gc_stats.total_bytes.to_f, suffix: "gc_total_bytes")
      yield Sample.new(gc_stats.unmapped_bytes.to_f, suffix: "gc_unmapped_bytes")
      yield Sample.new(gc_stats.bytes_since_gc.to_f, suffix: "bytes_since_gc")
      yield Sample.new(tms.stime + tms.utime, suffix: "cpu_seconds_total")
    end

    # A subclass of `StandardExports` that also reports process
    # information from procfs.
    # Generated by `Crometheus.make_standard_exports`.
    class ProcFSExports < StandardExports
      def initialize(name : Symbol,
                     docstring : String,
                     register_with : Crometheus::Registry? = Crometheus.default_registry,
                     @pid = Process.pid,
                     @procfs = "/proc")
        super(name, docstring, register_with)
      end

      def samples
        begin
          open_fds = 0
          Dir.each("#{@procfs}/#{@pid}/fd") do |node|
            open_fds += 1 unless "." == node || ".." == node
          end
          unless File.read_lines("#{@procfs}/#{@pid}/limits").find &.=~ /^Max open files\s+(\d+)/
            raise Exceptions::InstrumentationError.new(
              "\"Max open files\" not found in #{@procfs}/#{@pid}/limits")
          end
          max_fds = $1.to_f
          parts = File.read("#{@procfs}/#{@pid}/stat").split(")")[-1].split
          virtual_memory = parts[20].to_f
          resident_memory = parts[21].to_f * self.class.page_size
          start_time = @start_time || begin
            jiffies = parts[19].to_f
            tick_rate = LibC.sysconf(LibC::SC_CLK_TCK)
            unless File.read_lines("#{@procfs}/stat").find &.=~ /^btime\s+(\d+)/
              raise Exceptions::InstrumentationError.new("\"btime\" not found in #{@procfs}/stat")
            end
            boot_time = $1.to_f
            @start_time = (jiffies / tick_rate) + boot_time
          end
        rescue err : IO::Error
          raise Exceptions::InstrumentationError.new(
            "Error reading procfs: #{err.message}", err)
        rescue err : IndexError
          raise Exceptions::InstrumentationError.new(
            "Error reading procfs: #{@procfs}/#{@pid}/stat malformed?", err)
        end

        super { |sample| yield sample }

        yield Sample.new(open_fds.to_f, suffix: "open_fds")
        yield Sample.new(max_fds.to_f, suffix: "max_fds")
        yield Sample.new(virtual_memory.to_f, suffix: "virtual_memory_bytes")
        yield Sample.new(resident_memory.to_f, suffix: "resident_memory_bytes")
        yield Sample.new(start_time, suffix: "start_time_seconds")
      end

      protected def self.page_size
        @@page_size ||= LibC.getpagesize || 4096
      end
    end
  end

  # Checks for system capabilities and instantiates the appropriate
  # `StandardExports` type with the given arguments.
  # Will return an instance of either `StandardExports` or
  # `StandardExports::ProcFSExports`.
  # Unless disabled, each new `Registry` object will call this
  # automatically at creation.
  # See `Registry#new` and `default_registry`.
  def self.make_standard_exports(*args, **kwargs)
    pid = Process.pid
    if File.directory?("/proc/#{pid}/fd") && \
          File.file?("/proc/#{pid}/limits") && \
            File.file?("/proc/#{pid}/stat") && \
              File.file?("/proc/stat")
      StandardExports::ProcFSExports.new(*args, **kwargs)
    else
      StandardExports.new(*args, **kwargs)
    end
  end
end

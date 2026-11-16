# frozen_string_literal: true

# A stream read by external iteration and dropped half-read (docs/streaming.md
# says not to) must not take the process down: the Enumerator's Fiber is
# collected while it owns the connection's lock, which crashes Ruby 3.3.8 at
# a later collection or at exit unless the driver keeps that lock alive. The
# crash is the interpreter's, so it is looked for where it happens: in
# processes of their own, by their exit status.
require "test_helper"
require "rbconfig"
require "tempfile"

class AbandonedStreamTest < Minitest::Test
  CHILD = File.expand_path("abandoned_stream_child.rb", __dir__)
  LIB = File.expand_path("../lib", __dir__)
  RUNS = 3
  ROUNDS = 400 # abandoned streams per process; from 300 on every unprotected run crashes
  LIMIT = 60   # seconds: one way it ends is a spin at exit that ignores SIGTERM

  # Runs the child; its Process::Status (nil when it had to be killed) and
  # what it printed.
  def run_child
    Tempfile.create("abandoned-stream") do |out|
      pid = Process.spawn(RbConfig.ruby, "-I", LIB, "-I", __dir__, CHILD, ROUNDS.to_s,
                          in: File::NULL, out: out, err: out)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LIMIT
      status = nil
      until (status = Process.wait2(pid, Process::WNOHANG)&.last)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          Process.kill("KILL", pid)
          Process.wait(pid)
          break
        end
        sleep 0.02
      end
      out.rewind
      [status, out.read(4000).to_s]
    end
  end

  def test_a_process_that_drops_half_read_stream_enumerators_ends_normally
    RUNS.times do |run|
      status, printed = run_child
      refute_nil status, "run #{run + 1}: still running after #{LIMIT} s, killed\n#{printed}"
      assert status.success?, "run #{run + 1}: #{status.inspect}\n#{printed}"
    end
  end
end

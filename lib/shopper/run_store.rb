require "fileutils"
require_relative "run"
require_relative "log"

module Shopper
  # Keeps runs on disk (data/runs/<id>.bin) so a restart doesn't strand a basket awaiting review.
  # Marshal is used because runs hold Structs and Money objects; files are only ever written by this app.
  class RunStore
    ID = /\A[0-9a-f]{12}\z/

    def initialize(dir)
      @dir = dir
      @mutex = Mutex.new
      FileUtils.mkdir_p(dir)
    end

    def track(run)
      run.on_change = method(:save)
      save(run)
      run
    end

    def save(run)
      @mutex.synchronize do
        path = path_for(run.id)
        tmp = "#{path}.#{Thread.current.object_id}.tmp"
        File.binwrite(tmp, Marshal.dump(run))
        File.rename(tmp, path)
      end
    end

    def load(id)
      return nil unless id.to_s.match?(ID)
      path = path_for(id)
      return nil unless File.exist?(path)
      run = Marshal.load(File.binread(path)) # rubocop:disable Security/MarshalLoad
      return nil unless run.is_a?(Run)
      track(run)
      run.recover_after_restart!
      Log.info("run.restored", run_id: id, status: run.status)
      run
    rescue StandardError => e
      Log.warn("run.restore_failed", run_id: id, error_message: e.message)
      nil
    end

    private

    def path_for(id) = File.join(@dir, "#{id}.bin")
  end
end

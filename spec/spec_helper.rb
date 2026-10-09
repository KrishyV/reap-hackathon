ENV["RACK_ENV"] = "test"

require "prop_check"
require "webmock/rspec"
require "fileutils"
require_relative "../lib/shopper"

WebMock.disable_net_connect!

# Quiet: no stderr or file output, but keep everything in the in-memory ring buffer
# so specs can assert on emitted events.
Shopper::Log.configure(level: "error", file_level: "debug", file: nil, io: nil)

G = PropCheck::Generators
SPEC_TMP_ROOT = File.expand_path("../tmp/spec", __dir__)

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |f| require f }

module PropHelpers
  # Keeps the suite fast while still exploring plenty of cases.
  def forall(*args, runs: 150, **kwargs, &block)
    PropCheck.forall(*args, **kwargs).with_config(n_runs: runs, verbose: false).check(&block)
  end

  # Exactly lo..hi elements (G.array's min/max bounds are not inclusive of max in 1.0.2).
  def list_of(gen, lo, hi) = G.choose(lo..hi).bind { |n| n.zero? ? G.constant([]) : G.tuple(*Array.new(n) { gen }) }

  def usd(cents) = Shopper::Money.new(cents, "USD")
end

RSpec.configure do |config|
  config.include PropHelpers
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.before { Shopper::Log.clear! }
  config.after(:suite) { FileUtils.rm_rf(File.expand_path("../tmp", __dir__)) if Dir.exist?(SPEC_TMP_ROOT) }
end

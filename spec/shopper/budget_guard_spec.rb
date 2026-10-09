RSpec.describe Shopper::BudgetGuard do
  # op: [kind, hold slot, cents]; kind 0 = reserve, 1 = capture, 2 = release
  let(:ops_gen) { G.tuple(G.choose(0..50_000), list_of(G.tuple(G.choose(0..2), G.choose(0..4), G.choose(0..30_000)), 0, 25)) }

  it "keeps spent + held within budget and never captures more than was reserved" do
    forall(ops_gen, runs: 300) do |(budget_cents, ops)|
      guard = described_class.new(usd(budget_cents))
      model_holds = {}
      model_spent = 0

      ops.each do |kind, slot, cents|
        id = "h#{slot}"
        amount = usd(cents)
        case kind
        when 0
          if model_holds.key?(id)
            expect { guard.reserve!(id, amount) }.to raise_error(ArgumentError, /duplicate/)
          elsif model_spent + model_holds.values.sum + cents > budget_cents
            expect { guard.reserve!(id, amount) }.to raise_error(described_class::Exceeded)
          else
            guard.reserve!(id, amount)
            model_holds[id] = cents
          end
        when 1
          if !model_holds.key?(id)
            expect { guard.capture!(id, amount) }.to raise_error(described_class::UnknownHold)
          elsif cents > model_holds[id]
            expect { guard.capture!(id, amount) }.to raise_error(described_class::Exceeded)
          else
            guard.capture!(id, amount)
            model_spent += cents
            model_holds.delete(id)
          end
        when 2
          if model_holds.key?(id)
            guard.release!(id)
            model_holds.delete(id)
          else
            expect { guard.release!(id) }.to raise_error(described_class::UnknownHold)
          end
        end

        expect(guard.invariant_ok?).to be(true)
        expect((guard.spent + guard.held).cents).to be <= budget_cents
        expect(guard.spent.cents).to eq(model_spent)
        expect(guard.held.cents).to eq(model_holds.values.sum)
        expect(guard.remaining.cents).to eq(budget_cents - model_spent - model_holds.values.sum)
      end
    end
  end

  it "allows a hold to be resolved only once" do
    guard = described_class.new(usd(1000))
    guard.reserve!("h", usd(600))
    guard.capture!("h", usd(500))
    expect { guard.release!("h") }.to raise_error(described_class::UnknownHold)
    expect { guard.capture!("h", usd(1)) }.to raise_error(described_class::UnknownHold)
    expect(guard.remaining).to eq(usd(500))
  end

  it "is safe under concurrent reservations" do
    guard = described_class.new(usd(10_000))
    threads = 50.times.map { |i| Thread.new { guard.reserve!("h#{i}", usd(300)) rescue described_class::Exceeded } }
    threads.each(&:join)
    expect(guard.held).to eq(usd(9900))
    expect(guard.invariant_ok?).to be(true)
  end
end

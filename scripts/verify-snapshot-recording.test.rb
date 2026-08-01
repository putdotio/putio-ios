require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"

class VerifySnapshotRecordingTest < Minitest::Test
  SCRIPT = File.expand_path("verify-snapshot-recording.rb", __dir__)

  def test_accepts_record_mode_snapshot_failures
    result = run_verifier(payload(test_result: "Failed", failures: ["Record mode is on: recorded snapshot"]))

    assert result.success?
  end

  def test_rejects_unexpected_failures
    result = run_verifier(payload(test_result: "Failed", failures: ["Application crashed"]))

    refute result.success?
    assert_includes result.stderr, "Unexpected failures during snapshot recording"
  end

  def test_rejects_a_payload_without_test_cases
    result = run_verifier("testNodes" => [])

    refute result.success?
    assert_includes result.stderr, "No test cases found"
  end

  def test_rejects_a_run_without_record_mode_assertions
    result = run_verifier(payload(test_result: "Passed", failures: []))

    refute result.success?
    assert_includes result.stderr, "No record-mode snapshot assertions found"
  end

  private

  Result = Data.define(:stdout, :stderr, :status) do
    def success?
      status.success?
    end
  end

  def run_verifier(input)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, stdin_data: JSON.generate(input))
    Result.new(stdout:, stderr:, status:)
  end

  def payload(test_result:, failures:)
    {
      "testNodes" => [
        {
          "nodeType" => "Test Case",
          "result" => test_result,
          "children" => failures.map { |name| { "nodeType" => "Failure Message", "name" => name } }
        }
      ]
    }
  end
end

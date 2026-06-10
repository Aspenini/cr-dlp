require "./spec_helper"

describe CrDlp::SystemProcessRunner do
  it "executes shell commands and captures output" do
    result = CrDlp::SystemProcessRunner.new.run_shell("echo shell-output")
    result.success?.should be_true
    result.output.strip.should eq("shell-output")
  end

  it "streams input to a child process and captures its output" do
    crystal = Process.find_executable("crystal").not_nil!
    result = CrDlp::SystemProcessRunner.new.run_with_input(
      crystal,
      ["eval", "STDOUT.write(STDIN.gets_to_end.to_slice)"],
    ) do |input|
      input.write("streamed-input".to_slice)
    end

    result.success?.should be_true
    result.output.should eq("streamed-input")
    result.error.should be_empty
  end
end

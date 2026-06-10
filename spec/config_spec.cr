require "./spec_helper"

describe CrDlp::Config do
  it "tokenizes quoted values and comments" do
    CrDlp::Config.tokenize(%(--output "%(title)s file.%(ext)s" # comment)).should eq([
      "--output",
      "%(title)s file.%(ext)s",
    ])
  end

  it "reports malformed quotes" do
    expect_raises(CrDlp::UsageError, /Unterminated quote/) do
      CrDlp::Config.tokenize(%(--output "broken))
    end
  end
end

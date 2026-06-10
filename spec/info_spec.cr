require "./spec_helper"

describe CrDlp::Info do
  it "keeps the compatibility map as the JSON source of truth" do
    info = CrDlp::Info.new
    info["id"] = "abc"
    info["title"] = "Example"
    info["duration"] = 12

    reparsed = CrDlp::Info.parse(info.to_json)
    reparsed.id.should eq("abc")
    reparsed.title.should eq("Example")
    reparsed.int?("duration").should eq(12)
  end

  it "rejects missing required typed fields" do
    expect_raises(CrDlp::ExtractorError, /missing id/) do
      CrDlp::Info.new.id
    end
  end
end

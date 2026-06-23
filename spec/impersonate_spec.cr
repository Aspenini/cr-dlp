require "./spec_helper"

describe CrDlp::ImpersonateTarget do
  it "parses impersonate targets" do
    target = CrDlp::ImpersonateTarget.from_str("chrome-110:windows-10")
    target.client.should eq("chrome")
    target.version.should eq("110")
    target.os.should eq("windows")
    target.os_version.should eq("10")
    target.to_s.should eq("chrome-110:windows-10")
  end

  it "treats empty option values as any-client requests" do
    CrDlp::ImpersonateTarget.parse_option("").not_nil!.client.should be_nil
    CrDlp::ImpersonateTarget.parse_option(nil).should be_nil
  end

  it "matches broader supported targets" do
    broad = CrDlp::ImpersonateTarget.new("chrome")
    specific = CrDlp::ImpersonateTarget.new("chrome", "110", "windows", "10")
    broad.matches?(specific).should be_true
    specific.matches?(broad).should be_true
  end
end

describe CrDlp::ImpersonateTargets do
  it "lists known targets without error" do
    CrDlp::ImpersonateTargets::KNOWN_TARGETS.size.should be > 10
    CrDlp::ImpersonateTargets.available # smoke test
  end
end

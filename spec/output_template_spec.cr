require "./spec_helper"

private def template_info : CrDlp::Info
  CrDlp::Info.new({
    "id"                    => JSON::Any.new("1234"),
    "ext"                   => JSON::Any.new("mp4"),
    "height"                => JSON::Any.new(1080_i64),
    "width"                 => JSON::Any.new(nil),
    "filesize"              => JSON::Any.new(1024_i64),
    "title"                 => JSON::Any.new("foo/bar\\test"),
    "timestamp"             => JSON::Any.new(1_618_488_000_i64),
    "duration"              => JSON::Any.new(100_000_i64),
    "playlist_index"        => JSON::Any.new(1_i64),
    "playlist_autonumber"   => JSON::Any.new(2_i64),
    "__last_playlist_index" => JSON::Any.new(100_i64),
    "n_entries"             => JSON::Any.new(10_i64),
    "formats"               => JSON::Any.new([
      JSON::Any.new({
        "id"     => JSON::Any.new("id 1"),
        "height" => JSON::Any.new(1080_i64),
        "width"  => JSON::Any.new(1920_i64),
      }),
      JSON::Any.new({
        "id"     => JSON::Any.new("id 2"),
        "height" => JSON::Any.new(720_i64),
      }),
      JSON::Any.new({
        "id" => JSON::Any.new("id 3"),
      }),
    ]),
  })
end

describe CrDlp::OutputTemplate do
  it "supports shell-quoted values for exec templates" do
    info = CrDlp::Info.new({
      "filepath" => JSON::Any.new("file name's.mp4"),
    })
    rendered = CrDlp::OutputTemplate.new.render(
      "echo %(filepath)q",
      info,
      sanitize: false,
    )
    {% if flag?(:win32) %}
      rendered.should eq(%q(echo "file name's.mp4"))
    {% else %}
      rendered.should eq(%q(echo 'file name'"'"'s.mp4'))
    {% end %}
  end

  it "renders fields, numeric formats, missing defaults, and percent literals" do
    renderer = CrDlp::OutputTemplate.new
    info = template_info

    renderer.render("%(id)s.%(ext)s", info, sanitize: false).should eq("1234.mp4")
    renderer.render("%(height)06d", info, sanitize: false).should eq("001080")
    renderer.render("%(height)-6d", info, sanitize: false).should eq("1080  ")
    renderer.render("%(width)06d", info, sanitize: false).should eq("NA")
    renderer.render("%(x|def)s", info, sanitize: false).should eq("def")
    renderer.render("%(ext|def)d", info, sanitize: false).should eq("def")
    renderer.render("%%%(height)s", info, sanitize: false).should eq("%1080")
    renderer.render("%s %d %abc%", info, sanitize: false).should eq("%s %d %abc%")
  end

  it "supports alternatives, replacements, arithmetic, and datetime formatting" do
    renderer = CrDlp::OutputTemplate.new
    info = template_info

    renderer.render("%(title,id)s", info, sanitize: false).should eq("foo/bar\\test")
    renderer.render("%(missing,id)s", info, sanitize: false).should eq("1234")
    renderer.render("%(id&foo)s", info, sanitize: false).should eq("foo")
    renderer.render("%(id&{}!)s", info, sanitize: false).should eq("1234!")
    renderer.render("%(missing&foo|baz)s", info, sanitize: false).should eq("baz")
    renderer.render("%(id+1-height+3)05d", info, sanitize: false).should eq("00158")
    renderer.render("%(filesize*8)d", info, sanitize: false).should eq("8192")
    renderer.render("%(timestamp-1000>%H-%M-%S)s", info, sanitize: false).should eq("11-43-20")
  end

  it "traverses arrays, strings, and slices and renders lists and JSON" do
    renderer = CrDlp::OutputTemplate.new
    info = template_info

    renderer.render("%(formats.0.id)s", info, sanitize: false).should eq("id 1")
    renderer.render("%(formats.-1.id)s", info, sanitize: false).should eq("id 3")
    renderer.render("%(formats.:.id)l", info, sanitize: false).should eq("id 1, id 2, id 3")
    renderer.render("%(formats.:2.id)l", info, sanitize: false).should eq("id 1, id 2")
    renderer.render("%(formats.0.id.-1)d", info, sanitize: false).should eq("1")
    JSON.parse(renderer.render("%(formats)j", info, sanitize: false)).as_a.size.should eq(3)
  end

  it "generates compatibility fields and filename-safe values" do
    renderer = CrDlp::OutputTemplate.new
    info = template_info

    renderer.render("%(duration_string)s", info, sanitize: false).should eq("27:46:40")
    renderer.render("%(duration_string)s", info).should eq("27-46-40")
    renderer.render("%(resolution)s", info, sanitize: false).should eq("1080p")
    dimensions = template_info
    dimensions["width"] = 1920
    renderer.render("%(resolution)s", dimensions, sanitize: false).should eq("1920x1080")
    renderer.render("%(playlist_index)s", info, sanitize: false).should eq("001")
    renderer.render("%(playlist_autonumber)s", info, sanitize: false).should eq("02")
    renderer.render("%(autonumber)s", info, sanitize: false).should eq("00001")
    renderer.render("%(title)s", info).should eq("foo⧸bar⧹test")
  end

  it "supports html, unicode, bytes, and explicit sanitization conversions" do
    renderer = CrDlp::OutputTemplate.new
    info = CrDlp::Info.new({
      "title"    => JSON::Any.new("<tag>&'"),
      "filesize" => JSON::Any.new(7_i64),
    })

    renderer.render("%(title)h", info, sanitize: false).should eq("&lt;tag&gt;&amp;&#39;")
    renderer.render("%(title)U", info, sanitize: false).should eq("<tag>&'")
    bytes = renderer.render("%(filesize)010B", info, sanitize: false).to_slice
    bytes.should eq(Bytes[0, 0, 0, 0, 0, 0, 0, 0, 0, 55])
    {% if flag?(:win32) %}
      renderer.render("%(title)S", info, sanitize: false).should eq("＜tag＞&'")
    {% else %}
      renderer.render("%(title)S", info, sanitize: false).should eq("<tag>&'")
    {% end %}
    renderer.render("%(title)#S", info, sanitize: false).should eq("tag")
  end

  it "supports NA configuration, restricted filenames, and filename trimming" do
    missing = CrDlp::OutputTemplate.new(na_placeholder: "none")
    missing.render("%(width)s-%(x|def)s", template_info, sanitize: false).should eq("none-def")
    empty = CrDlp::OutputTemplate.new(na_placeholder: "")
    empty.render("%(missing)s", template_info).should eq("")

    restricted = CrDlp::OutputTemplate.new(restrict_filenames: true)
    unicode = CrDlp::Info.new({"title" => JSON::Any.new("áéí 𝐀")})
    restricted.render("%(title)s", unicode).should eq("aei_A")

    trimmed = CrDlp::OutputTemplate.new(trim_file_name: 5)
    trimmed.render("folder/%(id)s-long-name.%(ext)s", template_info, sanitize: false)
      .should eq(File.join("folder", "1234-.mp4"))
  end
end

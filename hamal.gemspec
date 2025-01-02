require_relative "lib/hamal"

Gem::Specification.new do |spec|
  spec.name = "hamal"
  spec.version = Hamal::VERSION
  spec.authors = ["Genadi Samokovarov"]
  spec.email = ["gsamokovarov@gmail.com"]

  spec.summary = "Hamal is a simple deploy tool for self-hosted Rails application"
  spec.homepage = "https://github.com/gsamokovarov/hamal"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/gsamokovarov/hamal"
  spec.metadata["changelog_uri"] = "https://github.com/gsamokovarov/hamal/releases"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end

  spec.bindir = "exe"
  spec.executables = "hamal"
  spec.require_paths = ["lib"]

  spec.add_dependency "json"

  spec.metadata["rubygems_mfa_required"] = "true"
end

lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "eventbox/version"

Gem::Specification.new do |spec|
  spec.name          = "eventbox"
  spec.version       = Eventbox::VERSION
  spec.authors       = ["Lars Kanis"]
  spec.email         = ["lars@greiz-reinsdorf.de"]

  if File.read("README.md", encoding: 'utf-8') =~ /^_(.*?)_$\s^\n(.*?)\n$/m
    spec.summary = $1
    spec.description = $2
  end
  spec.homepage      = "https://github.com/larskanis/eventbox"
  spec.license       = "MIT"

  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.0", "< 4.0"
  spec.metadata["yard.run"] = "yri" # use "yard" to build full HTML docs.

  spec.add_development_dependency "bundler", ">= 1.16", "< 3"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "minitest-hooks"
  spec.add_development_dependency "yard", "~> 0.9"
end

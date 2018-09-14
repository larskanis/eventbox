lib = File.expand_path("../lib", __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "eventbox/version"

Gem::Specification.new do |spec|
  spec.name          = "eventbox"
  spec.version       = Eventbox::VERSION
  spec.authors       = ["Lars Kanis"]
  spec.email         = ["lars@greiz-reinsdorf.de"]

  spec.summary       = %q{Manage multithreading with the safety of event based programming}
  spec.description   = %q{Eventbox objects are event based from the inside but thread safe from the outside. All code inside an Eventbox object is executed sequentially and avoids data races through filters applied to all inputs and outputs. That way Eventbox garanties stable objects without a need for any locks.}
  spec.homepage      = "https://github.com/larskanis/eventbox"
  spec.license       = "MIT"

  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.16"
  spec.add_development_dependency "rake", "~> 10.0"
  spec.add_development_dependency "minitest", "~> 5.0"
end

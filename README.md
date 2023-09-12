# perf-tools

An assortment of tools to track resources in Crystal applications.

## Usage

```crystal
require "perf_tools/mem_prof"

PerfTools::MemProf.log_object_counts(STDOUT)
PerfTools::MemProf.log_object_sizes(STDOUT)
PerfTools::MemProf.log_allocations(STDOUT)
PerfTools::MemProf.pretty_log_allocations(STDOUT)
```

```crystal
require "perf_tools/fiber_trace"

PerfTools::FiberTrace.pretty_log_fibers(STDOUT)
```

Check each tool's instructions for more information.

## Installation

Add this to your application's `shard.yml`:

```yml
development_dependencies:
  perf-tools:
    github: crystal-lang/perf-tools
```

## Contributing

1. Fork it ( <https://github.com/crystal-lang/perf-tools/fork> )
2. Create your feature branch (git checkout -b my-new-feature)
3. Commit your changes (git commit -am 'Add some feature')
4. Push to the branch (git push origin my-new-feature)
5. Create a new Pull Request

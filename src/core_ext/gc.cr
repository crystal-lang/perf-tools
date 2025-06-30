{% if flag?(:gc_none) || flag?(:wasm32) %}
  require "./gc/none"
{% else %}
  require "./gc/boehm"
{% end %}

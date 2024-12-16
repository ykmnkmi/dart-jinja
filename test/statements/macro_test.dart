@TestOn('vm || chrome')
library;

import 'package:jinja/jinja.dart';
import 'package:test/test.dart';

void main() {
  var env = Environment(trimBlocks: true);

  group('Macro', () {
    test('simple', () {
      var tmpl = env.fromString('''
{% macro say_hello(name) %}Hello {{ name }}!{% endmacro %}
{{ say_hello('Peter') }}''');
      expect(tmpl.render(), equals('Hello Peter!'));
    });

    test('scoping', () {
      var tmpl = env.fromString('''
{% macro level1(data1) %}
{% macro level2(data2) %}{{ data1 }}|{{ data2 }}{% endmacro %}
{{ level2('bar') }}{% endmacro %}
{{ level1('foo') }}''');
      expect(tmpl.render(), equals('foo|bar'));
    });

    test('arguments', () {
      var tmpl = env.fromString('''
{% macro m(a, b, c='c', d='d') %}{{ a }}|{{ b }}|{{ c }}|{{ d }}{% endmacro %}
{{ m('a', 'b') }}|{{ m(1, 2, c=3) }}''');
      expect(tmpl.render(), equals('a|b|c|d|1|2|3|d'));
    });

    test('arguments defaults nonsense', () {
      expect(() {
        env.fromString('''
{% macro m(a, b=1, c) %}a={{ a }}, b={{ b }}, c={{ c }}{% endmacro %}''');
      }, throwsA(isA<TemplateSyntaxError>()));
    });

    test('caller defaults nonsense', () {
      expect(() {
        env.fromString('''
{% macro a() %}{{ caller() }}{% endmacro %}
{% call(x, y=1, z) a() %}{% endcall %}''');
      }, throwsA(isA<TemplateSyntaxError>()));
    });

    test('varargs', () {
      var tmpl = env.fromString('''
{% macro test() %}{{ varargs|join('|') }}{% endmacro -%}
{{ test(1, 2, 3) }}''');
      expect(tmpl.render(), equals('1|2|3'));
    });

    test('simple call', () {
      var tmpl = env.fromString('''
{% macro test() %}[[{{ caller() }}]]{% endmacro -%}
{% call test() %}data{% endcall %}''');
      expect(tmpl.render(), equals('[[data]]'));
    });

    test('complex call', () {
      var tmpl = env.fromString('''
{% macro test() %}[[{{ caller('data') }}]]{% endmacro -%}
{% call(data) test() %}{{ data }}{% endcall %}''');
      expect(tmpl.render(), equals('[[data]]'));
    });

    test('caller undefined', () {
      var tmpl = env.fromString('''
{% set caller = 42 -%}
{% macro test() %}{{ caller is not defined }}{% endmacro -%}
{{ test() }}''');
      expect(tmpl.render(), equals('true'));
    });

    test('include', () {
      var env = Environment(
        loader: MapLoader({
          'include': '{% macro test(foo) %}[{{ foo }}]{% endmacro %}',
        }),
      );

      var tmpl = env.fromString('''
{% from "include" import test -%}
{{ test("foo") }}''');
      expect(tmpl.render(), equals('[foo]'));
    });

    test('macro api', () {}, skip: 'Not supported.');

    test('callself', () {
      var tmpl = env.fromString('{% macro foo(x) %}{{ x }}{% if x > 1 %}|'
          '{{ foo(x - 1) }}{% endif %}{% endmacro %}'
          '{{ foo(5) }}');
      expect(tmpl.render(), equals('5|4|3|2|1'));
    });

    test('macro defaults self ref', () {
      var tmpl = env.fromString('''
{% set x = 42 %}
{% macro m(a, b=x, x=23) %}{{ a }}|{{ b }}|{{ x }}{% endmacro -%}
{{ m(1) }},{{ m(1, b=2) }},{{ m(1, b=2, x=3) }},{{ m(1, x=7) }}''');
      expect(tmpl.render(), equals('1||23,1|2|23,1|2|3,1|7|7'));
    });
  });

  group('Macro and Extends', () {
    var sources = <String, String>{
      'macro': '''
{% macro hey(name) %}hello {{ name }}!{% endmacro %}
''',
      'base': '''
{% block content %}{% endblock %}
''',
      'global': '''
{% extends 'base' %}

{% import 'macro' as macro %}

{% block content -%}
  {{ macro.hey('world') }}
{%- endblock %}
''',
      'inblock': '''
{% extends 'base' %}


{% block content -%}
  {%- import 'macro' as macro -%}
  {{ macro.hey('world') }}
{%- endblock %}
''',
    };

    var loaded = MapLoader(sources);
    var environment = Environment(loader: loaded, leftStripBlocks: true);

    test('global import', () {
      var template = environment.getTemplate('global');
      expect(template.render(), equals('hello world!'));
    });

    test('import in block', () {
      var template = environment.getTemplate('inblock');
      expect(template.render(), equals('hello world!'));
    });
  });
}

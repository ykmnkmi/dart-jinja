import 'package:jinja/src/environment.dart';

typedef ContextCallback = void Function(Context context);

base class Context {
  Context(
    this.environment, {
    this.template,
    Map<String, List<ContextCallback>>? blocks,
    this.parent = const <String, Object?>{},
    Map<String, Object?>? data,
  })  : blocks = blocks ?? <String, List<ContextCallback>>{},
        context = <String, Object?>{...?data};

  final Environment environment;

  String? template;

  final Map<String, List<ContextCallback>> blocks;

  final Map<String, Object?> parent;

  final Map<String, Object?> context;

  Object? call(
    dynamic object, [
    List<Object?> positional = const <Object?>[],
    Map<Symbol, Object?> named = const <Symbol, Object?>{},
  ]) {
    Function function;

    if (object is Function) {
      function = object;
    } else {
      // TODO(dynamic): dynamic invocation
      // ignore: avoid_dynamic_calls
      function = object.call as Function;
    }

    return environment.callCommon(function, positional, named, this);
  }

  Context derived({
    String? template,
    Map<String, Object?>? data,
  }) {
    return Context(
      environment,
      template: template ?? this.template,
      blocks: blocks,
      parent: parent,
      data: data,
    );
  }

  bool has(String key) {
    if (context.containsKey(key)) {
      return true;
    }

    return parent.containsKey(key);
  }

  Object? resolve(String name) {
    if (context.containsKey(name)) {
      return context[name];
    }

    if (parent.containsKey(name)) {
      return parent[name];
    }

    return undefined(name, template);
  }

  Object? get(String key) {
    return context[key];
  }

  void set(String key, Object? value) {
    context[key] = value;
  }

  bool remove(String name) {
    if (context.containsKey(name)) {
      context.remove(name);
      return true;
    }

    return false;
  }

  Object? undefined(String name, [String? template]) {
    return environment.undefined(name, template);
  }

  Object? attribute(String name, Object? value) {
    return environment.getAttribute(name, value);
  }

  Object? item(Object? name, Object? value) {
    return environment.getItem(name, value);
  }

  Object? filter(
    String name, [
    List<Object?> positional = const <Object?>[],
    Map<Symbol, Object?> named = const <Symbol, Object?>{},
  ]) {
    return environment.callFilter(name, positional, named, this);
  }

  bool test(
    String name, [
    List<Object?> positional = const <Object?>[],
    Map<Symbol, Object?> named = const <Symbol, Object?>{},
  ]) {
    return environment.callTest(name, positional, named, this);
  }
}

final class LoopContext extends Iterable<Object?> {
  LoopContext(this.values, this.depth0, this.recurse)
      : length = values.length,
        index0 = -1;

  final List<Object?> values;

  @override
  final int length;

  final int depth0;

  final String Function(Object? data, [int depth]) recurse;

  int index0;

  @override
  LoopIterator get iterator {
    return LoopIterator(this);
  }

  int get index {
    return index0 + 1;
  }

  int get depth {
    return depth0 + 1;
  }

  int get revindex0 {
    return length - index;
  }

  int get revindex {
    return length - index0;
  }

  @override
  bool get first {
    return index0 == 0;
  }

  @override
  bool get last {
    return index == length;
  }

  Object? get next {
    if (last) {
      return null;
    }

    return values[index0 + 1];
  }

  Object? get prev {
    if (first) {
      return null;
    }

    return values[index0 - 1];
  }

  Object? operator [](String key) {
    return switch (key) {
      'length' => length,
      'index0' => index0,
      'depth0' => depth0,
      'index' => index,
      'depth' => depth,
      'revindex0' => revindex0,
      'revindex' => revindex,
      'first' => first,
      'last' => last,
      'prev' || 'previtem' => prev,
      'next' || 'nextitem' => next,
      'call' => call,
      'cycle' => cycle,
      'changed' => changed,
      _ => throw NoSuchMethodError.withInvocation(
          this, Invocation.getter(Symbol(key))),
    };
  }

  String call(Object? data) {
    return recurse(data, depth);
  }

  Object? cycle(Iterable<Object?> values) {
    var list = values is List ? values : values.toList();

    if (list.isEmpty) {
      // TODO(loop): update error
      throw TypeError();
    }

    return list[index0 % list.length];
  }

  bool changed(Object? item) {
    return index0 == 0 || item != prev;
  }
}

final class LoopIterator implements Iterator<Object?> {
  LoopIterator(this.context);

  final LoopContext context;

  @override
  Object? get current {
    return context.values[context.index0];
  }

  @override
  bool moveNext() {
    if (context.index < context.length) {
      context.index0 += 1;
      return true;
    }

    return false;
  }
}

final class Cycler extends Iterable<Object?> {
  Cycler(Iterable<Object?> values)
      : values = List<Object?>.of(values),
        length = values.length,
        index = 0;

  final List<Object?> values;

  @override
  final int length;

  int index;

  Object? get current {
    return values[index];
  }

  @override
  Iterator<Object?> get iterator {
    return CyclerIterator(this);
  }

  Object? next() {
    var result = current;
    index = (index + 1) % length;
    return result;
  }

  void reset() {
    index = 0;
  }
}

final class CyclerIterator implements Iterator<Object?> {
  CyclerIterator(this.cycler);

  final Cycler cycler;

  @override
  Object? current;

  @override
  bool moveNext() {
    current = cycler.next();
    return true;
  }
}

base class Namespace {
  Namespace([Map<String, Object?>? data])
      : context = <String, Object?>{...?data};

  final Map<String, Object?> context;

  Object? operator [](String name) {
    return context[name];
  }

  void operator []=(String name, Object? value) {
    context[name] = value;
  }

  static Namespace factory([List<Object?>? datas]) {
    var namespace = Namespace();

    if (datas == null) {
      return namespace;
    }

    for (var data in datas) {
      if (data is! Map) {
        // TODO(namespace): update error
        throw TypeError();
      }

      namespace.context.addAll(data.cast<String, Object?>());
    }

    return namespace;
  }
}

final class NamespaceValue {
  NamespaceValue(this.name, this.item);

  final String name;

  final String item;
}

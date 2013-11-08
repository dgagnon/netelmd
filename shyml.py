#!/usr/bin/env python
import pprint, json
import sys
import yaml
import os.path

EXNAME = os.path.basename(sys.argv[0])

from collections import defaultdict

def dicts(t):
    try:
        return dict((k, dicts(t[k])) for k in t)
    except TypeError:
        return t

def out(t):
  pprint.pprint(dicts(t))
#  print "--------"

def tree(): return defaultdict(tree)

def add(t, tkeys, value):
  i = 0
  keys = tkeys.split('.')
  for key in keys:
    i = i + 1
    if i == len(keys) and value != None:
      t[key] = value
    t = t[key]


def get(dct, key, default=None):
    """Allow to get values deep in a dict with doted keys.

    >>> get({'a': {'x': 1, 'b': {'c': 2}}}, "a.x")
    1
    >>> get({'a': {'x': 1, 'b': {'c': 2}}}, "a.b.c")
    2
    >>> get({'a': {'x': 1, 'b': {'c': 2}}}, "a.b")
    {'c': 2}
    >>> get({'a': {'x': [1, 5], 'b': {'c': 2}}}, "a.x.-1")
    5
    >>> get({'a': {'x': 1, 'b': [{'c': 2}]}}, "a.b.0.c")
    2

    >>> get({'a': {'x': 1, 'b': {'c': 2}}}, "a.y", default='N/A')
    'N/A'

    """
    if key == "":
        return dct
    if not "." in key:
        if isinstance(dct, list):
            return dct[int(key)]
        return dct.get(key, default)
    else:
        head, tail = key.split(".", 1)
        value = dct[int(head)] if isinstance(dct, list) else dct.get(head, {})
        return get(value, tail, default)


def stderr(msg):
    sys.stderr.write(msg + "\n")


def die(msg, errlvl=1, prefix="Error: "):
    stderr("%s%s" % (prefix, msg))
    sys.exit(errlvl)


SIMPLE_TYPES = (basestring, int, float)
COMPLEX_TYPES = (list, dict)

def dump(value):
    return value if isinstance(value, SIMPLE_TYPES) \
      else yaml.dump(value, default_flow_style=False)

def type_name(value):
    """Returns pseudo-YAML type name of given value."""
    return "struct" if isinstance(value, dict) else \
          "sequence" if isinstance(value, (tuple, list)) else \
          type(value).__name__

def stdout(value):
    sys.stdout.write(value)


def main(args):
    usage = """usage:
    %(exname)s filename.yaml {get-value{,-0},get-type,keys{,-0},values{,-0},add-value} KEY DEFAULT
    """ % {"exname": EXNAME}
    if len(args) == 0:
        die(usage, errlvl=0, prefix="")
    yfile = args[0]
    action = args[1]
   
    try:
        key_value = "" if len(args) == 1 else args[2]
    except: key_value = ""

    default = args[3] if len(args) > 3 else ""
    config = tree()
    try:
        with open(yfile, 'r') as f:
            config['raid'].update(yaml.load(f)['raid'])
        f.close()
    except:
    	pass
    
    try:
        value = get(config, key_value, default)
    except IndexError:
        die("list index error in path %r." % key_value)
    except KeyError, TypeError:
        die("invalid path %r." % key_value)

    tvalue = type_name(value)
    termination = "\0" if action.endswith("-0") else "\n"

    if action == "get-value":
        print dump(value),
    elif action == "get-value-raw":
        print out(value)
    elif action in ("get-values", "get-values-0"):
        if isinstance(value, dict):
            for k, v in value.iteritems():
                stdout("%s%s%s%s" % (dump(k), termination,
                                     dump(v), termination))
        elif isinstance(value, list):
            for l in value:
                stdout("%s%s" % (dump(l), termination))
        else:
            die("%s does not support %r type. "
                "Please provide or select a sequence or struct."
                % (action, tvalue))
    elif action == "get-type":
        print tvalue
    elif action in ("keys", "keys-0", "values", "values-0"):
        if isinstance(value, dict):
            method = value.keys if action.startswith("keys") else value.values
            for k in method():
                stdout("%s%s" % (dump(k), termination))
        else:
            die("%s does not support %r type. "
                "Please provide or select a struct." % (action, tvalue))
    elif action == "add-value":
        add(config, key_value, default)
    elif action == "print":
        out(config)
    else:
        die("Invalid argument.\n%s" % usage)

    f = open(yfile, 'w')
    yaml.dump(config, f)
    f.close

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

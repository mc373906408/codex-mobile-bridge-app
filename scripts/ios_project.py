"""Read the OpenStep subset used by Xcode projects, without a macOS dependency."""

import json
import re

TOKEN = re.compile(r'\s+|//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}()=;,]|[^\s{}()=;,]+')


def parse_project(source):
    tokens = [match.group() for match in TOKEN.finditer(source)
              if not match.group().isspace() and not match.group().startswith(("//", "/*"))]
    index = 0

    def take(expected=None):
        nonlocal index
        if index >= len(tokens):
            raise ValueError("Truncated Xcode project")
        token = tokens[index]
        index += 1
        if expected is not None and token != expected:
            raise ValueError(f"Expected {expected}, got {token}")
        return json.loads(token) if token.startswith('"') else token

    def value():
        if index >= len(tokens):
            raise ValueError("Missing project value")
        if tokens[index] == "{":
            take("{")
            result = {}
            while tokens[index] != "}":
                key = take()
                if key in result:
                    raise ValueError(f"Duplicate project key: {key}")
                take("=")
                result[key] = value()
                take(";")
            take("}")
            return result
        if tokens[index] == "(":
            take("(")
            result = []
            while tokens[index] != ")":
                result.append(value())
                if tokens[index] == ",":
                    take(",")
                elif tokens[index] != ")":
                    raise ValueError("Missing array separator")
            take(")")
            return result
        return take()

    try:
        result = value()
    except IndexError as exc:
        raise ValueError("Truncated Xcode project") from exc
    if index != len(tokens) or not isinstance(result, dict):
        raise ValueError("Invalid Xcode project root")
    return result

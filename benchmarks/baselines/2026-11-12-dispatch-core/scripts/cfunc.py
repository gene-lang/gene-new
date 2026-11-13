"""Print the line range of a C function body: cfunc.py FILE START_LINE"""
import sys
path, start = sys.argv[1], int(sys.argv[2])
lines = open(path, encoding='latin-1').read().split('\n')
depth = 0; seen = False
i = start - 1
while i < len(lines):
    s = lines[i]; j = 0
    while j < len(s):
        c = s[j]
        if c == '"' or c == "'":
            q = c; j += 1
            while j < len(s) and s[j] != q:
                if s[j] == '\\': j += 1
                j += 1
        elif c == '/' and j + 1 < len(s) and s[j+1] == '*':
            k = s.find('*/', j + 2)
            if k < 0:
                # multi-line comment
                i += 1
                while i < len(lines) and '*/' not in lines[i]: i += 1
                s = lines[i]; j = s.find('*/') + 1
            else:
                j = k + 1
        elif c == '/' and j + 1 < len(s) and s[j+1] == '/':
            break
        elif c == '{':
            depth += 1; seen = True
        elif c == '}':
            depth -= 1
            if seen and depth == 0:
                print(start, i + 1); sys.exit(0)
        j += 1
    i += 1

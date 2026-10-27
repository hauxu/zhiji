#ifndef RUNNER_UTILS_H_
#define RUNNER_UTILS_H_

#include <string>
#include <vector>

// Creates a console and redirects stdout/stderr.
void CreateAndAttachConsole();

// UTF-16 -> UTF-8; empty string on failure.
std::string Utf8FromUtf16(const wchar_t* utf16_string);

// UTF-8 command line arguments; empty vector on failure.
std::vector<std::string> GetCommandLineArguments();

#endif  // RUNNER_UTILS_H_

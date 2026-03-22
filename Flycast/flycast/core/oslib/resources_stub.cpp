/*
	Stub implementation of resources.cpp for Xcode builds without CMake Resource Compiler (cmrc).
	Returns empty/null for all resource loads since OpenEmu provides its own UI.
*/
#include "resources.h"

namespace resource
{

std::unique_ptr<u8[]> load(const std::string& path, size_t& size)
{
	size = 0;
	return nullptr;
}

std::vector<std::string> listDirectory(const std::string& path)
{
	return {};
}

}

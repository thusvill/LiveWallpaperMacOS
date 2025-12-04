#pragma once
#include <yaml-cpp/yaml.h>
#include <list>
#include <string>
#include <CoreGraphics/CoreGraphics.h>
#include "DisplayManager.h" 



class SaveSystem {
public:
    static void Save(const std::list<Display>& displays);
    static std::list<Display> Load();
};

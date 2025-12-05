#include "SaveSystem.h"
#include <filesystem>
#include <fstream>

static std::string configPath() {
  const char *home = getenv("HOME");
  return std::string(home) + "/Library/Preferences/LiveWallpaper.yaml";
}

// ------------------------
// YAML Conversion
// ------------------------
namespace YAML {

template <> struct convert<Display> {
  static Node encode(const Display &d) {
    Node node;
    node["uuid"] = d.uuid; 
    
    node["video"] = d.videoPath;
    node["frame"] = d.framePath;
    node["daemon"] = (int)d.daemon;
    return node;
  }

  static bool decode(const Node &node, Display &d) {

    
    if (node["uuid"])
      d.uuid = node["uuid"].as<std::string>();
    else
      d.uuid = "";

    
    

    
    d.videoPath = node["video"] ? node["video"].as<std::string>() : "";
    d.framePath = node["frame"] ? node["frame"].as<std::string>() : "";
    d.daemon = node["daemon"] ? (pid_t)node["daemon"].as<int>() : 0;

    return true;
  }
};

} // namespace YAML

// ------------------------
// Save
// ------------------------
void SaveSystem::Save(const std::list<Display> &displays) {
  YAML::Node root;

  for (const auto &d : displays)
    root["displays"].push_back(d);

  std::ofstream out(configPath(), std::ios::trunc);
  out << root;
}

// ------------------------
// Load
// ------------------------
std::list<Display> SaveSystem::Load() {
  std::list<Display> result;

  const auto path = configPath();
  if (!std::filesystem::exists(path))
    return result;

  YAML::Node root = YAML::LoadFile(path);

  if (!root["displays"])
    return result;

  for (auto node : root["displays"]) {

    Display d;
    d = node.as<Display>();
    d.screen = DisplayIDFromUUID(d.uuid);
    result.push_back(d);
  }

  return result;
}

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional
import omegaconf
from omegaconf import OmegaConf

class EmbeddingsTag(Enum):
    PINECONE = "pinecone"

class EmbeddingsType(Enum):
    BEDROCK = "bedrock"

@dataclass
class EmbeddingsConfig:
    provider_tag: EmbeddingsTag = omegaconf.MISSING
    embeddings_type: EmbeddingsType = omegaconf.MISSING

@dataclass
class PineconeConfig:
    index_name: str = omegaconf.MISSING

@dataclass
class BedrockConfig:
    region_name: str = "us-east-1"
    embeddings_model_id: str = "amazon.titan-embed-text-v1"

@dataclass
class EmbeddingsMainConfig:
    provider: EmbeddingsConfig = field(default_factory=EmbeddingsConfig)
    pinecone: Optional[PineconeConfig] = None
    bedrock: Optional[BedrockConfig] = None

    @staticmethod
    def from_file(yaml_path: str) -> "EmbeddingsMainConfig":
        conf = OmegaConf.structured(EmbeddingsMainConfig)
        conf = OmegaConf.merge(conf, OmegaConf.load(yaml_path))
        return conf

if __name__ == "__main__":
    cfg = EmbeddingsMainConfig()
    yaml_str = OmegaConf.to_yaml(cfg)

    conf = OmegaConf.structured(EmbeddingsMainConfig)
    conf = OmegaConf.merge(conf, OmegaConf.load("configs/Embeddings/pinecone.yaml"))
    print(conf)
